export type UpgradeHeaders = {
  host?: string;
  authorization?: string;
  origin?: string;
};

export function authorizeUpgrade(headers: UpgradeHeaders, remoteAddress: string | undefined, token: string): boolean {
  const remote = remoteAddress?.replace(/^::ffff:/, "");
  if (remote !== "127.0.0.1" && remote !== "::1") return false;
  if (headers.origin) return false;
  const host = headers.host?.split(":")[0]?.replace(/^\[|\]$/g, "");
  if (host !== "127.0.0.1" && host !== "localhost" && host !== "::1") return false;
  return headers.authorization === `Bearer ${token}`;
}
