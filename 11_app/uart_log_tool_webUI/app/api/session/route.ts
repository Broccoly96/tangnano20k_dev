import { NextResponse } from "next/server";

import { getWorkbenchService } from "@/lib/workbench/service";
import type { ActionEnvelope, ConnectPayload } from "@/lib/workbench/types";

export const runtime = "nodejs";

export async function GET() {
  const service = getWorkbenchService();
  return NextResponse.json(service.getSnapshot());
}

export async function POST(request: Request) {
  const service = getWorkbenchService();
  try {
    const body = (await request.json()) as ActionEnvelope<ConnectPayload>;
    if (body.action !== "connect") {
      return NextResponse.json({ error: "unsupported session action" }, { status: 400 });
    }
    await service.connect(body.payload ?? { transport: "tcp" });
    return NextResponse.json(service.getSnapshot());
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : `${error}` },
      { status: 500 },
    );
  }
}