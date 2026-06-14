// Quran Tasmee3 — Cloudflare Worker (ASR-only).
//
// Trimmed per the backend spec to exactly two routes:
//   GET  /health           → liveness
//   POST /asr/transcribe   → Firebase-ID-token-protected Groq Whisper proxy
//
// All previous D1/JWT auth/sessions/plans routes are removed (that data now
// lives in Firestore). Requests are authenticated with the caller's Firebase
// ID token (RS256), verified against Google's JWKS.

import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose';

interface Env {
  GROQ_API_KEY: string; // existing Worker secret — unchanged
  FIREBASE_PROJECT_ID?: string; // secret or [vars]; defaults to tasmeea-497bf
}

const DEFAULT_PROJECT_ID = 'tasmeea-497bf';

const GROQ_URL = 'https://api.groq.com/openai/v1/audio/transcriptions';
const GROQ_MODEL = 'whisper-large-v3';

// Google's Secure Token Service JWK Set (cached across requests by jose).
const JWKS = createRemoteJWKSet(
  new URL(
    'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
  ),
);

const app = new Hono<{ Bindings: Env }>();

app.use('*', cors());

app.get('/health', (c) => c.json({ status: 'ok' }, 200));

/**
 * Verify a Firebase ID token. Throws on any failure (caught by the route).
 * Checks signature (RS256 via JWKS), issuer, audience, and expiry.
 */
async function verifyFirebaseToken(
  token: string,
  projectId: string,
): Promise<JWTPayload> {
  const { payload } = await jwtVerify(token, JWKS, {
    issuer: `https://securetoken.google.com/${projectId}`,
    audience: projectId,
    // jose enforces `exp` automatically; allow a little clock skew.
    clockTolerance: 5,
  });
  if (!payload.sub) throw new Error('missing sub');
  return payload;
}

// --- best-effort per-uid rate limit (per isolate; see note) ------------------
// Workers isolates are ephemeral and not shared globally, so this is a soft
// guard, not a hard quota. For strict limits use a Durable Object or KV.
const RATE_WINDOW_MS = 10_000;
const RATE_MAX = 30;
const hits = new Map<string, number[]>();

function rateLimited(uid: string): boolean {
  const now = Date.now();
  const arr = (hits.get(uid) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
  arr.push(now);
  hits.set(uid, arr);
  return arr.length > RATE_MAX;
}

app.post('/asr/transcribe', async (c) => {
  const projectId = c.env.FIREBASE_PROJECT_ID || DEFAULT_PROJECT_ID;

  // 1) Authn — Firebase ID token.
  const auth = c.req.header('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  if (!token) return c.json({ error: 'unauthorized' }, 401);

  let uid: string;
  try {
    const payload = await verifyFirebaseToken(token, projectId);
    uid = payload.sub as string;
  } catch {
    return c.json({ error: 'unauthorized' }, 401);
  }

  if (rateLimited(uid)) return c.json({ error: 'rate_limited' }, 429);

  // 2) Read the uploaded chunk.
  let form: FormData;
  try {
    form = await c.req.formData();
  } catch {
    // Malformed body → treat as empty audio (not an error).
    return c.json({ text: '', confidence: 0 }, 200);
  }
  const entry = form.get('file');
  if (entry === null || typeof entry === 'string') {
    return c.json({ text: '', confidence: 0 }, 200);
  }
  // `entry` is a file part (Blob/File) at runtime. workers-types doesn't expose
  // the DOM `File` type, so read its shape structurally.
  const file = entry as unknown as { size: number; name?: string };
  if (file.size === 0) {
    return c.json({ text: '', confidence: 0 }, 200);
  }

  // 3) Proxy to Groq Whisper.
  const groqForm = new FormData();
  groqForm.append('file', entry as unknown as Blob, file.name || 'chunk.m4a');
  groqForm.append('model', GROQ_MODEL);
  groqForm.append('language', 'ar');
  groqForm.append('response_format', 'verbose_json');
  groqForm.append('temperature', '0');

  let groqRes: Response;
  try {
    groqRes = await fetch(GROQ_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${c.env.GROQ_API_KEY}` },
      body: groqForm,
    });
  } catch {
    return c.json({ error: 'asr_failed' }, 502);
  }
  if (!groqRes.ok) {
    return c.json({ error: 'asr_failed' }, 502);
  }

  const data = (await groqRes.json()) as {
    text?: string;
    segments?: Array<{ avg_logprob?: number; no_speech_prob?: number }>;
  };

  const text = (data.text ?? '').trim();
  const segments = data.segments ?? [];
  const confidence = text.length === 0 ? 0 : confidenceFromSegments(segments);

  return c.json({ text, confidence, segments }, 200);
});

/**
 * Derive a 0..1 confidence from Whisper segments. `avg_logprob` is the mean
 * token log-probability; `exp(avg_logprob)` approximates per-segment
 * confidence. Falls back to 0.9 when no usable segment data is present.
 */
function confidenceFromSegments(
  segments: Array<{ avg_logprob?: number; no_speech_prob?: number }>,
): number {
  const vals: number[] = [];
  for (const s of segments) {
    if (typeof s.avg_logprob === 'number') {
      let conf = Math.exp(s.avg_logprob);
      if (typeof s.no_speech_prob === 'number') {
        conf *= 1 - s.no_speech_prob;
      }
      vals.push(conf);
    }
  }
  if (vals.length === 0) return 0.9;
  const avg = vals.reduce((a, b) => a + b, 0) / vals.length;
  return Math.max(0, Math.min(1, avg));
}

// Fallback for any other route.
app.all('*', (c) => c.json({ error: 'not_found' }, 404));

export default app;
