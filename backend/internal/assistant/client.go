// Package assistant wraps the Claude API for Sokoni's in-app support
// assistant — the thing behind Profile's "Help and Support" tile, which
// answered nothing at all until this existed (onTap: null, see the mobile
// UX audit this was written for).
//
// Grounding, not chat: the caller (gateway.Service.Assist) gathers the
// account's real balances and recent activity and passes them in as plain
// text alongside the question. The system prompt instructs the model to
// answer only from what it's given and from general Sokoni/crypto
// knowledge, never to invent a balance, a transaction, or a reason a trade
// failed — the one thing worse than "Help and Support" doing nothing is it
// confidently making something up.
package assistant

import (
	"context"
	"fmt"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/anthropics/anthropic-sdk-go/vertex"
)

const systemPrompt = `You are Sokoni's in-app support assistant. Sokoni is a passkey-native mobile trading app on Monad: users sign transactions with their device's biometric (Face ID / fingerprint) or a connected external wallet, never a seed phrase, and Sokoni's paymaster sponsors gas so an account never needs to hold MON to trade.

You will be given the user's real, current account data (balances and recent activity) before their question. Answer ONLY from that data and from general knowledge about Sokoni, Monad, passkeys, and crypto trading — never invent a balance, a transaction, an amount, or a reason something failed. If the answer isn't in the data you were given, say so plainly rather than guessing.

Keep answers short — a few sentences, not an essay. This is a mobile chat bubble, not a document.`

// maxTokens bounds a support answer, not a document — see systemPrompt's own
// "a few sentences" instruction. Generous headroom over what a few sentences
// actually costs, so a genuinely longer explanation never gets cut off
// mid-thought.
const maxTokens = 1024

// Client talks to the Claude API. model is a plain string (e.g.
// "claude-sonnet-5"), never a typed SDK constant — those lag model launches,
// and the API accepts any current model id as a string.
type Client struct {
	api   anthropic.Client
	model string
}

func New(apiKey, model string) *Client {
	return &Client{
		api:   anthropic.NewClient(option.WithAPIKey(apiKey)),
		model: model,
	}
}

// NewVertex authenticates through a GCP project's Vertex AI instead of a
// direct Anthropic API key — the free-trial-credit path (Vertex gives new
// GCP projects $300 over 90 days; the direct API's own signup credit is
// unconfirmed as of this writing). Auth is ADC (Application Default
// Credentials): on a VPS that means GOOGLE_APPLICATION_CREDENTIALS pointing
// at a service account key file, the standard chain anthropic-sdk-go's
// vertex.WithGoogleAuth resolves on its own — nothing Sokoni-specific to
// configure beyond the file existing.
//
// model is still a bare id like "claude-sonnet-5": current-generation
// models take no Vertex prefix or @-version suffix, unlike a dated snapshot.
func NewVertex(ctx context.Context, projectID, region, model string) *Client {
	return &Client{
		api:   anthropic.NewClient(vertex.WithGoogleAuth(ctx, region, projectID)),
		model: model,
	}
}

// Ask answers one question, grounded in `grounding` — plain text the caller
// has already assembled from the account's real balances/activity. Not a
// multi-turn conversation: each question is independent, so there is no
// history to manage and no cross-question cache to invalidate.
func (c *Client) Ask(ctx context.Context, question, grounding string) (string, error) {
	msg := fmt.Sprintf("Account data:\n%s\n\nQuestion: %s", grounding, question)
	resp, err := c.api.Messages.New(ctx, anthropic.MessageNewParams{
		Model:     anthropic.Model(c.model),
		MaxTokens: maxTokens,
		System:    []anthropic.TextBlockParam{{Text: systemPrompt}},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(msg)),
		},
	})
	if err != nil {
		return "", fmt.Errorf("assistant: %w", err)
	}
	for _, block := range resp.Content {
		if b, ok := block.AsAny().(anthropic.TextBlock); ok {
			return b.Text, nil
		}
	}
	return "", fmt.Errorf("assistant: no text in response")
}
