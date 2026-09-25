import { buildQuestions, mapAnswers, MODEL, validateInput } from "./draft.ts";

type Config = { supabaseURL: string; publishableKey: string; typesafeKey: string };
const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
const reply = (status: number, code: string) => new Response(JSON.stringify({ code }), { status, headers });

export async function boundedJSON(response: Request | Response, limit: number): Promise<unknown> {
  if (!response.body) throw new Error("empty_body");
  const reader = response.body.getReader();
  let bytes = 0;
  const parts: Uint8Array[] = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.length;
      if (bytes > limit) throw new Error("body_too_large");
      parts.push(value);
    }
  } finally { await reader.cancel(); }
  const data = new Uint8Array(bytes);
  let offset = 0;
  for (const part of parts) { data.set(part, offset); offset += part.length; }
  return JSON.parse(new TextDecoder().decode(data));
}

export function createHandler(config: Config, request: typeof fetch = fetch) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return reply(405, "method_not_allowed");
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) return reply(401, "sign_in_required");
    try {
      // The platform gateway alone also accepts API keys. Require a live, non-anonymous user here.
      const authHeaders = { apikey: config.publishableKey, Authorization: authorization, "Content-Type": "application/json" };
      const auth = await request(`${config.supabaseURL}/auth/v1/user`, { headers: authHeaders, signal: AbortSignal.timeout(8000) });
      if (!auth.ok) return reply(401, "sign_in_required");
      const user = await auth.json();
      if (!user.id || user.is_anonymous === true) return reply(403, "sign_in_required");
      let input;
      try { input = validateInput(await boundedJSON(req, 32_000)); }
      catch { return reply(400, "invalid_input"); }
      if (!config.typesafeKey) return reply(503, "drafting_unavailable");
      const budget = await request(`${config.supabaseURL}/rest/v1/rpc/consume_hang_draft`, {
        method: "POST", headers: authHeaders, body: "{}", signal: AbortSignal.timeout(8000),
      });
      if (!budget.ok) return reply(budget.status === 429 ? 429 : budget.status === 403 ? 403 : 503,
        budget.status === 429 ? "rate_limited" : budget.status === 403 ? "sign_in_required" : "drafting_unavailable");
      const questions = buildQuestions(input);
      const result = await request("https://api.typesafe.ai/v1/systemone", {
        method: "POST", headers: { Authorization: `Bearer ${config.typesafeKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model: MODEL, state: input,
          questions: Object.fromEntries(Object.entries(questions).filter(([, q]) => Object.keys(q.criteria).length > 1)) }),
        signal: AbortSignal.timeout(20_000),
      });
      if (!result.ok) return reply(result.status === 429 || result.status === 529 ? 429 : 502,
        result.status === 429 || result.status === 529 ? "rate_limited" : "drafting_unavailable");
      const draft = mapAnswers(input, questions, await boundedJSON(result, 160_000));
      return new Response(JSON.stringify(draft), { status: 200, headers });
    } catch {
      // Never log the transcript, vendor response, credentials, or user identity.
      return reply(503, "drafting_unavailable");
    }
  };
}
