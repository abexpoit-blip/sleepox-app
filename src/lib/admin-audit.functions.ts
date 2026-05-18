import { createServerFn } from "@tanstack/react-start";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { auditAdminGate } from "./admin-audit.server";
import { z } from "zod";

export const listAuditLogs = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((input) =>
    z
      .object({
        limit: z.number().int().min(1).max(500).default(100),
        statusFilter: z.enum(["all", "success", "denied", "error"]).default("all"),
      })
      .parse(input),
  )
  .handler(async ({ data, context }) => {
    await auditAdminGate({
      userId: context.userId,
      action: "audit.view",
    });

    let q = supabaseAdmin
      .from("admin_audit_logs")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(data.limit);

    if (data.statusFilter !== "all") q = q.eq("status", data.statusFilter);

    const { data: rows, error } = await q;
    if (error) throw new Error(error.message);
    return { rows: rows ?? [] };
  });
