import { NextResponse } from "next/server";
import { readFeed, writeFeed } from "@/lib/feed";

export async function GET() {
  const f = readFeed();
  return NextResponse.json(
    { price: f.price, pair: f.pair, asOf: f.asOf, desk: f.desk },
    { headers: { "Cache-Control": "no-store" } },
  );
}

export async function POST(req: Request) {
  try {
    const body = (await req.json()) as { price?: unknown };
    return NextResponse.json(writeFeed(Number(body.price)));
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "bad" },
      { status: 400 },
    );
  }
}
