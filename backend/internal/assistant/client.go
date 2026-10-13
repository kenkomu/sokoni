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
//
// Grounding has a fixed shape, though — this account's balances and its
// last 10 activity rows, decided before the question is even read — so it
// can't answer "what's the price of BTC-USDC right now" or "show me more
// than 10". gateway.Service.assistTools hands Ask a short list of
// read-only tools for exactly that gap; Ask runs the resulting tool-use
// loop itself (see maxToolRounds), since the Go SDK's own ToolRunner is
// Beta-only and this stays on the stable Messages API.
package assistant

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
	"github.com/anthropics/anthropic-sdk-go/packages/param"
	"github.com/anthropics/anthropic-sdk-go/vertex"

	"github.com/kenkomu/sokoni/backend/internal/gateway"
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

// maxToolRounds bounds the tool-use loop in Ask. Each of the three tools
// gateway.Service.assistTools hands in is one read against this account's
// own data, so a genuine question never needs more than one or two; this is
// headroom against the model double-checking, not a budget it's expected to
// spend fully. The SDK's own ToolRunner (tools.md) only exists on the Beta
// surface, so this loop is hand-rolled over the stable Messages API.
const maxToolRounds = 4

// Ask answers one question, grounded in `grounding` — plain text the caller
// has already assembled from the account's real balances/activity — plus
// whatever tools lets the model fetch beyond that (a live price, more
// activity rows). Not a multi-turn conversation across questions: each
// question starts a fresh message history: there is no cross-question cache
// to invalidate. Within one question, though, the model may call a tool,
// read its result, and call another before answering — that loop is what
// this function runs.
func (c *Client) Ask(ctx context.Context, question, grounding string, tools []gateway.Tool) (gateway.Answer, error) {
	byName := make(map[string]gateway.Tool, len(tools))
	toolParams := make([]anthropic.ToolUnionParam, 0, len(tools))
	for _, t := range tools {
		byName[t.Name] = t
		tp := anthropic.ToolUnionParamOfTool(anthropic.ToolInputSchemaParam{
			Properties: t.Properties,
			Required:   t.Required,
		}, t.Name)
		tp.OfTool.Description = param.NewOpt(t.Description)
		toolParams = append(toolParams, tp)
	}

	msg := fmt.Sprintf("Account data:\n%s\n\nQuestion: %s", grounding, question)
	messages := []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(msg))}

	var displays []gateway.DisplayPart
	for round := 0; round < maxToolRounds; round++ {
		resp, err := c.api.Messages.New(ctx, anthropic.MessageNewParams{
			Model:     anthropic.Model(c.model),
			MaxTokens: maxTokens,
			System:    []anthropic.TextBlockParam{{Text: systemPrompt}},
			Messages:  messages,
			Tools:     toolParams,
		})
		if err != nil {
			return gateway.Answer{}, fmt.Errorf("assistant: %w", err)
		}

		var text string
		var assistantBlocks []anthropic.ContentBlockParamUnion
		var toolUses []anthropic.ToolUseBlock
		for _, block := range resp.Content {
			switch b := block.AsAny().(type) {
			case anthropic.TextBlock:
				text += b.Text
				assistantBlocks = append(assistantBlocks, anthropic.NewTextBlock(b.Text))
			case anthropic.ToolUseBlock:
				toolUses = append(toolUses, b)
				assistantBlocks = append(assistantBlocks, anthropic.NewToolUseBlock(b.ID, b.Input, b.Name))
			}
		}

		if resp.StopReason != anthropic.StopReasonToolUse || len(toolUses) == 0 {
			if text == "" {
				return gateway.Answer{}, fmt.Errorf("assistant: no text in response")
			}
			return gateway.Answer{Text: text, Displays: displays}, nil
		}

		messages = append(messages, anthropic.NewAssistantMessage(assistantBlocks...))

		resultBlocks := make([]anthropic.ContentBlockParamUnion, 0, len(toolUses))
		for _, tu := range toolUses {
			tool, ok := byName[tu.Name]
			if !ok {
				resultBlocks = append(resultBlocks, anthropic.NewToolResultBlock(tu.ID, "unknown tool", true))
				continue
			}
			result, err := tool.Run(ctx, json.RawMessage(tu.Input))
			if err != nil {
				resultBlocks = append(resultBlocks, anthropic.NewToolResultBlock(tu.ID, err.Error(), true))
				continue
			}
			if result.Display != nil {
				displays = append(displays, *result.Display)
			}
			resultBlocks = append(resultBlocks, anthropic.NewToolResultBlock(tu.ID, result.Text, false))
		}
		messages = append(messages, anthropic.NewUserMessage(resultBlocks...))
	}
	return gateway.Answer{}, fmt.Errorf("assistant: exceeded %d tool-call rounds", maxToolRounds)
}
