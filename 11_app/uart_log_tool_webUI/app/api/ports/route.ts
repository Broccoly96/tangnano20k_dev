import { NextResponse } from "next/server";

import { getWorkbenchService } from "@/lib/workbench/service";

export const runtime = "nodejs";

export async function GET() {
  try {
    const service = getWorkbenchService();
    return NextResponse.json(await service.listPorts());
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : `${error}` },
      { status: 500 },
    );
  }
}