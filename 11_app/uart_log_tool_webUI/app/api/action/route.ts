import { NextResponse } from "next/server";

import { getWorkbenchService } from "@/lib/workbench/service";
import type { ActionEnvelope } from "@/lib/workbench/types";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const service = getWorkbenchService();
  try {
    const body = (await request.json()) as ActionEnvelope;
    await service.dispatchAction(body.action, body.payload);
    return NextResponse.json(service.getSnapshot());
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : `${error}` },
      { status: 500 },
    );
  }
}