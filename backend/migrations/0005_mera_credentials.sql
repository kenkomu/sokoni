-- Option 2 / Mera path: an account owned by a plain ECDSA key (derived on
-- the phone from a passkey's WebAuthn PRF output via Mera's vault scheme —
-- see mobile/lib/data/mera/) instead of a P-256 WebAuthn credential.
--
-- Mirrors `credentials`' relationship to `accounts` exactly, keyed by the
-- owner address instead of a WebAuthn credential id. The encrypted vault
-- itself is never sent here: it lives in the phone's own secure storage,
-- gated by the same passkey used to sign, so the gateway never sees key
-- material even encrypted. All this table needs to know is "which address
-- owns which smart account."

begin;

create table if not exists mera_credentials (
  owner_address  bytea primary key,             -- ECDSA address derived from the Mera vault
  account_id     bigint not null references accounts(account_id),
  created_at     timestamptz not null default now()
);
create index if not exists mera_credentials_account_idx on mera_credentials(account_id);

commit;
