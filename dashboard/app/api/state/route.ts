import { snapshot } from "@/lib/manager";

export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json(await snapshot());
}
