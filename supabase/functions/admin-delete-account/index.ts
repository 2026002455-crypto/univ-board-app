import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return respond(405, { error: "Method not allowed." });

  const authorization = request.headers.get("Authorization");
  if (!authorization) return respond(401, { error: "Authentication required." });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) return respond(500, { error: "Server configuration is incomplete." });

  const callerClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const adminClient = createClient(url, serviceRoleKey);

  const { data: authData, error: authError } = await callerClient.auth.getUser();
  if (authError || !authData.user) return respond(401, { error: "Invalid session." });

  const { data: callerProfile, error: callerProfileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", authData.user.id)
    .maybeSingle();
  if (callerProfileError) return respond(500, { error: "Could not verify the site admin." });
  if (callerProfile?.role !== "admin") return respond(403, { error: "Only a site admin may delete site accounts." });

  let body: { userId?: string };
  try {
    body = await request.json();
  } catch {
    return respond(400, { error: "Invalid request body." });
  }

  const targetUserId = body.userId?.trim() ?? "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(targetUserId)) {
    return respond(400, { error: "Invalid user id." });
  }
  if (targetUserId === authData.user.id) return respond(403, { error: "You cannot delete your own account." });

  const { data: targetProfile, error: targetProfileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", targetUserId)
    .maybeSingle();
  if (targetProfileError) return respond(500, { error: "Could not verify the target account." });
  if (targetProfile?.role === "admin") return respond(403, { error: "The site admin account is protected." });

  const { error: postsError } = await adminClient
    .from("posts")
    .update({ author_label: "탈퇴한 회원", author_id: null })
    .eq("author_id", targetUserId);
  if (postsError) return respond(500, { error: "Could not preserve authored posts." });

  const { error: commentsError } = await adminClient
    .from("comments")
    .update({ author_label: "탈퇴한 회원", author_id: null })
    .eq("author_id", targetUserId);
  if (commentsError) return respond(500, { error: "Could not preserve authored comments." });

  for (const table of ["board_operators", "memberships", "post_likes"]) {
    const { error } = await adminClient.from(table).delete().eq("user_id", targetUserId);
    if (error) return respond(500, { error: `Could not clean up ${table}.` });
  }

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(targetUserId);
  if (deleteError) return respond(500, { error: "Content was anonymized, but Auth account deletion failed." });

  return respond(200, { ok: true });
});
