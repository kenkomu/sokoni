#!/usr/bin/env python3
"""Generate a real WebAuthn assertion vector for the Solidity tests.

Pure Python P-256 so the vector is reproducible on any machine with no
dependencies, and so the test fixtures in the repo can be regenerated and
audited rather than pasted in from somewhere unverifiable.

A WebAuthn assertion is NOT a plain signature over a challenge. The
authenticator signs:

    sha256( authenticatorData || sha256(clientDataJSON) )

and the challenge only appears inside clientDataJSON, base64url encoded. A
contract that verifies a bare P-256 signature over the challenge would accept
signatures the authenticator never made for this origin — so the test vector
has to carry the real structure.
"""

import hashlib
import json
import base64

# secp256r1 (P-256) domain parameters, SEC 2 / FIPS 186-4.
P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
A = P - 3
B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551


def inv(x, m):
    return pow(x, -1, m)


def point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2 and (y1 + y2) % P == 0:
        return None
    if p1 == p2:
        lam = (3 * x1 * x1 + A) * inv(2 * y1, P) % P
    else:
        lam = (y2 - y1) * inv(x2 - x1, P) % P
    x3 = (lam * lam - x1 - x2) % P
    y3 = (lam * (x1 - x3) - y1) % P
    return (x3, y3)


def scalar_mul(k, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        k >>= 1
    return result


def sign(digest: bytes, priv: int, k: int):
    """ECDSA over P-256. k is passed in so the vector is deterministic."""
    z = int.from_bytes(digest, "big")
    point = scalar_mul(k, (GX, GY))
    r = point[0] % N
    s = inv(k, N) * (z + r * priv) % N
    assert r and s
    return r, s


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def build(challenge: bytes, priv: int, k: int, origin: str, rp_id: str, flags: int):
    pub = scalar_mul(priv, (GX, GY))

    # clientDataJSON. Key order matters: it is what the browser produces and
    # what the contract slices by index.
    client_data = (
        '{"type":"webauthn.get","challenge":"'
        + b64url(challenge)
        + '","origin":"'
        + origin
        + '","crossOrigin":false}'
    )
    client_data_bytes = client_data.encode()
    client_data_hash = hashlib.sha256(client_data_bytes).digest()

    # authenticatorData = rpIdHash(32) || flags(1) || signCount(4)
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    auth_data = rp_id_hash + bytes([flags]) + (0).to_bytes(4, "big")

    message = auth_data + client_data_hash
    digest = hashlib.sha256(message).digest()

    r, s = sign(digest, priv, k)

    # Normalise to low-s. Both (r,s) and (r,N-s) verify, so an attacker could
    # otherwise mutate a signature and keep it valid. The contract requires
    # low-s and the client normalises before submitting.
    high_s = s
    if s > N // 2:
        s = N - s

    return {
        "privateKey": hex(priv),
        "x": hex(pub[0]),
        "y": hex(pub[1]),
        "challenge": "0x" + challenge.hex(),
        "challengeB64": b64url(challenge),
        "clientDataJSON": client_data,
        "authenticatorData": "0x" + auth_data.hex(),
        "digest": "0x" + digest.hex(),
        "r": hex(r),
        "s": hex(s),
        "sHigh": hex(N - s if s <= N // 2 else high_s),
        "typeIndex": client_data.index('"type":"'),
        "challengeIndex": client_data.index('"challenge":"'),
        "flags": flags,
        "origin": origin,
        "rpId": rp_id,
    }


# Fixed private key: a test vector must be reproducible. Test-only values;
# these must never appear anywhere near a real key path.
PRIV = 0x1F2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F809
SECOND_PRIV = 0x3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8091A2B


def nonce_for(digest: bytes, priv: int) -> int:
    """A deterministic per-message nonce.

    Reusing k across two signatures leaks the private key, so it must vary with
    the message. This is not RFC 6979 and is for test fixtures only.
    """
    k = int.from_bytes(hashlib.sha256(digest + priv.to_bytes(32, "big")).digest(), "big")
    return k % (N - 1) + 1


def assertion(challenge: bytes, priv: int, flags: int = 0x05, ctype: str = "webauthn.get"):
    """Build an assertion, choosing k from the message so signing is safe."""
    pub = scalar_mul(priv, (GX, GY))
    client_data = (
        '{"type":"' + ctype + '","challenge":"'
        + b64url(challenge)
        + '","origin":"https://sokoni.app","crossOrigin":false}'
    )
    client_data_hash = hashlib.sha256(client_data.encode()).digest()
    auth_data = hashlib.sha256(b"sokoni.app").digest() + bytes([flags]) + (0).to_bytes(4, "big")
    digest = hashlib.sha256(auth_data + client_data_hash).digest()

    r, s = sign(digest, priv, nonce_for(digest, priv))
    if s > N // 2:  # normalise; the contract rejects malleable high-s
        s = N - s

    return {
        "x": "0x%064x" % pub[0],
        "y": "0x%064x" % pub[1],
        "authenticatorData": "0x" + auth_data.hex(),
        "clientDataJSON": client_data,
        "challengeIndex": client_data.index('"challenge":"'),
        "typeIndex": client_data.index('"type":"'),
        "r": "0x%064x" % r,
        "s": "0x%064x" % s,
    }


if __name__ == "__main__":
    import sys

    args = sys.argv[1:]

    # ffi mode: `--sign <0x-challenge> [--key second]` emits the JSON the
    # Foundry tests decode, so a test can sign a userOpHash it only learns at
    # runtime instead of being limited to a frozen fixture.
    if args and args[0] == "--sign":
        challenge = bytes.fromhex(args[1].removeprefix("0x"))
        priv = SECOND_PRIV if "second" in args else PRIV
        flags = 0x01 if "no-uv" in args else 0x05
        ctype = "webauthn.create" if "create" in args else "webauthn.get"
        print(json.dumps(assertion(challenge, priv, flags, ctype)))
        raise SystemExit(0)

    if args and args[0] == "--pubkey":
        priv = SECOND_PRIV if "second" in args else PRIV
        pub = scalar_mul(priv, (GX, GY))
        print(json.dumps({"x": "0x%064x" % pub[0], "y": "0x%064x" % pub[1]}))
        raise SystemExit(0)

    # Default: print the frozen fixture used by WebAuthn.t.sol.
    K = 0x2A3B4C5D6E7F8091A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D5E6F70819
    challenge = hashlib.sha256(b"sokoni-userop-hash-v1").digest()
    v = build(
        challenge=challenge,
        priv=PRIV,
        k=K,
        origin="https://sokoni.app",
        rp_id="sokoni.app",
        flags=0x05,  # UP (user present) | UV (user verified)
    )
    print(json.dumps(v, indent=2))
