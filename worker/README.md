# Quran Tasmee3 — Cloudflare Worker (ASR-only)

The only server-side code: a Groq Whisper ASR proxy, protected by Firebase ID
tokens. Deploys in place to:

```
https://quran-tasmee3-backend.abdelrahman-khamis.workers.dev
```

## Routes

| Method | Path | Auth | Behavior |
|--------|------|------|----------|
| GET | `/health` | none | `200 {"status":"ok"}` |
| POST | `/asr/transcribe` | `Authorization: Bearer <Firebase ID token>` | Verifies the token (RS256 via Google JWKS, issuer `https://securetoken.google.com/tasmeea-497bf`, audience `tasmeea-497bf`, expiry). Forwards the `file` part to Groq Whisper (`whisper-large-v3`, Arabic). |

**Contract preserved:**
- success → `{ text, confidence, segments }` (confidence derived from Whisper `avg_logprob` × `1 - no_speech_prob`)
- empty/malformed audio → `200 { text: "", confidence: 0 }`
- Groq error / network failure → `502 { error: "asr_failed" }`
- bad/missing token → `401 { error: "unauthorized" }`
- soft per-uid rate limit → `429 { error: "rate_limited" }`

All old D1 / JWT-auth / sessions / plans routes are removed (that data lives in
Firestore now). `GROQ_API_KEY` remains an existing Worker secret — read from
`env.GROQ_API_KEY`, unchanged.

## Deploy (run where your Cloudflare credentials live)

These commands need `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` in the
environment (or `npx wrangler login`). They are **not** present in the cloud dev
sandbox, so deploy from your machine:

```bash
cd worker
npm install

# Store the project id as a secret (the code defaults to tasmeea-497bf if
# you skip this):
npx wrangler secret put FIREBASE_PROJECT_ID    # enter: tasmeea-497bf

# GROQ_API_KEY is already a Worker secret from before — nothing to do.

npx wrangler deploy
```

## Verify

```bash
# 1) health → 200
curl -i https://quran-tasmee3-backend.abdelrahman-khamis.workers.dev/health

# 2) no token → 401
curl -i -X POST \
  https://quran-tasmee3-backend.abdelrahman-khamis.workers.dev/asr/transcribe

# 3) real token from a logged-in test user (grab it in the app via
#    FirebaseAuth.instance.currentUser!.getIdToken(), or from the debug print):
TOKEN="<firebase-id-token>"
curl -i -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -F "mode=normal" \
  -F "file=@sample.m4a" \
  https://quran-tasmee3-backend.abdelrahman-khamis.workers.dev/asr/transcribe
# → 200 { "text": "...", "confidence": 0.x, "segments": [...] }
```

Once deployed, the Flutter app's `GroqAsrService` (already sending the Firebase
token) will start receiving real transcriptions and revealing words.
