import { createHandler } from "./handler.ts";

Deno.serve(createHandler({
  supabaseURL: Deno.env.get("SUPABASE_URL") ?? "",
  publishableKey: Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "",
  typesafeKey: Deno.env.get("TYPESAFE_API_KEY") ?? "",
}));
