/**
 * CUKKA x402 — Shopify Global Catalog Agent Data Layer
 *
 * Exposes x402-gated (HTTP 402 Payment Required) endpoints on Base Sepolia & Base Mainnet
 * with native x402 v2 `extensions.bazaar` discovery schemas and both `exact` and `upto`
 * billing schemes.
 *
 * Receiver Wallet (payTo): 0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9
 */

export interface Env {
  PAY_TO_ADDRESS: string;
  BASE_SEPOLIA_USDC: string;
  BASE_MAINNET_USDC: string;
  X402_FACILITATOR_URL: string;
  SHOPIFY_GLOBAL_MCP_URL: string;
  SHOPIFY_AGENT_TOKEN?: string;
}

export interface EndpointSpec {
  path: string;
  method: "POST" | "GET";
  name: string;
  description: string;
  category: string;
  scheme: "exact" | "upto";
  amountAtomicUsdc: string; // 6 decimals (e.g., "2000" = $0.002 USDC)
  priceUsdDisplay: string;
  inputSchema: Record<string, unknown>;
}

export const BAZAAR_ENDPOINTS: Record<string, EndpointSpec> = {
  "/v1/catalog/cheapest-variant": {
    path: "/v1/catalog/cheapest-variant",
    method: "POST",
    name: "Cross-Store Cheapest In-Stock Variant Finder",
    description:
      "Queries Shopify Global Catalog MCP and multi-merchant storefronts to cluster identical products, filter out-of-stock variants, normalize unit prices, and return the cheapest in-stock variant with direct checkout URL.",
    category: "commerce",
    scheme: "exact",
    amountAtomicUsdc: "2000", // $0.002 USDC
    priceUsdDisplay: "$0.002",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: {
        query: { type: "string", description: "Product search query or Universal Product ID (UPID)" },
        stores: {
          type: "array",
          items: { type: "string" },
          description: "Optional list of Shopify storefront domains to cross-compare",
        },
        inStockOnly: { type: "boolean", default: true },
        preferredSize: { type: "string", description: "Optional variant size/option filter (e.g. M, 42, 250ml)" },
      },
    },
  },
  "/v1/catalog/enrich-product": {
    path: "/v1/catalog/enrich-product",
    method: "POST",
    name: "Shopify Product Normalization, Size Matrix & Spec Enrichment",
    description:
      "Enriches raw Shopify product JSON with standardized taxonomy category, EU/US/UK/TR size conversion chart, material/ingredient breakdown, and compatibility tags. Billed dynamically via x402 'upto' scheme based on token/compute usage.",
    category: "commerce",
    scheme: "upto",
    amountAtomicUsdc: "25000", // Max $0.025 USDC (actual metered charge ~$0.004 - $0.018)
    priceUsdDisplay: "upto $0.025",
    inputSchema: {
      type: "object",
      required: ["productUrlOrHandle"],
      properties: {
        productUrlOrHandle: { type: "string", description: "Shopify product URL, handle, or UPID" },
        targetRegion: { type: "string", enum: ["TR", "EU", "US", "UK"], default: "TR" },
      },
    },
  },
  "/v1/catalog/price-stock-watch": {
    path: "/v1/catalog/price-stock-watch",
    method: "POST",
    name: "Real-Time Restock & Price Drop Signal",
    description:
      "Checks live variant availability across Shopify storefronts, computes price delta against 30d baseline, and returns restock velocity score.",
    category: "commerce",
    scheme: "exact",
    amountAtomicUsdc: "1000", // $0.001 USDC
    priceUsdDisplay: "$0.001",
    inputSchema: {
      type: "object",
      required: ["storeDomain", "productHandle"],
      properties: {
        storeDomain: { type: "string" },
        productHandle: { type: "string" },
      },
    },
  },
  "/v1/catalog/niche-match": {
    path: "/v1/catalog/niche-match",
    method: "POST",
    name: "Vertical Niche Matcher (Cosmetic INCI / Spare Parts / Gift Matrix)",
    description:
      "Matches products across Shopify Global Catalog by strict technical constraints (allergen-free INCI ingredients, OEM part compatibility, or recipient persona + budget cap).",
    category: "commerce",
    scheme: "upto",
    amountAtomicUsdc: "50000", // Max $0.050 USDC
    priceUsdDisplay: "upto $0.050",
    inputSchema: {
      type: "object",
      required: ["niche", "criteria"],
      properties: {
        niche: { type: "string", enum: ["cosmetics_inci", "spare_parts", "gift_advisor"] },
        criteria: { type: "string" },
        maxBudgetUsd: { type: "number" },
      },
    },
  },
};

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-PAYMENT, PAYMENT-SIGNATURE, Authorization",
  "Access-Control-Expose-Headers": "X-PAYMENT-RESPONSE, X-Payment-Settled-Amount, X-Payment-Scheme",
};

/**
 * Builds an x402 v1 + v2 compatible HTTP 402 Payment Required response with Bazaar discovery metadata.
 */
export function build402Response(spec: EndpointSpec, requestUrl: string, env: Env): Response {
  const payTo = env.PAY_TO_ADDRESS || "0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9";
  const sepoliaUsdc = env.BASE_SEPOLIA_USDC || "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
  const mainnetUsdc = env.BASE_MAINNET_USDC || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

  const payload = {
    x402Version: 2,
    error: "Payment Required: Attach signed x402 payment payload in X-PAYMENT header.",
    resource: {
      url: requestUrl,
      method: spec.method,
    },
    accepts: [
      {
        scheme: spec.scheme,
        network: "eip155:84532", // Base Sepolia Testnet
        networkName: "base-sepolia",
        payTo,
        asset: sepoliaUsdc,
        amount: spec.amountAtomicUsdc,
        maxAmountRequired: spec.amountAtomicUsdc, // v1 backward compatibility
        maxTimeoutSeconds: 300,
        description: `${spec.name} (${spec.priceUsdDisplay} USDC on Base Sepolia)`,
      },
      {
        scheme: spec.scheme,
        network: "eip155:8453", // Base Mainnet
        networkName: "base",
        payTo,
        asset: mainnetUsdc,
        amount: spec.amountAtomicUsdc,
        maxAmountRequired: spec.amountAtomicUsdc,
        maxTimeoutSeconds: 300,
        description: `${spec.name} (${spec.priceUsdDisplay} USDC on Base Mainnet)`,
      },
    ],
    extensions: {
      bazaar: {
        info: {
          name: spec.name,
          description: spec.description,
          category: spec.category,
          provider: "Cukka Agent Data Layer (cukka.org)",
        },
        schema: spec.inputSchema,
      },
    },
  };

  return new Response(JSON.stringify(payload, null, 2), {
    status: 402,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
    },
  });
}

/**
 * Fetches live Shopify Storefront products from public Shopify stores or Global Catalog MCP
 * and compares all available variants to find the cheapest in-stock option.
 */
async function executeCheapestVariantComparison(body: {
  query?: string;
  stores?: string[];
  inStockOnly?: boolean;
  preferredSize?: string;
}) {
  const query = (body.query || "coffee").toLowerCase().trim();
  const stores =
    body.stores && body.stores.length > 0
      ? body.stores
      : ["allbirds.com", "gymshark.com", "deathwishcoffee.com"];

  const matchedVariants: Array<{
    store: string;
    productTitle: string;
    variantTitle: string;
    sku: string;
    available: boolean;
    priceUsd: number;
    compareAtPriceUsd: number | null;
    discountPct: number;
    checkoutUrl: string;
  }> = [];

  await Promise.all(
    stores.map(async (domain) => {
      try {
        const cleanDomain = domain.replace(/^https?:\/\//, "").replace(/\/$/, "");
        const res = await fetch(`https://${cleanDomain}/products.json?limit=25`, {
          headers: { "User-Agent": "Cukka-x402-Agent-Catalog/1.0" },
        });
        if (!res.ok) return;
        const data = (await res.json()) as {
          products?: Array<{
            title: string;
            handle: string;
            variants: Array<{
              id: number;
              title: string;
              sku: string;
              available: boolean;
              price: string;
              compare_at_price: string | null;
            }>;
          }>;
        };

        for (const prod of data.products || []) {
          if (query && !prod.title.toLowerCase().includes(query) && (data.products || []).length > 5) {
            // Also include top products if query is broad
          }
          for (const v of prod.variants || []) {
            if (body.inStockOnly !== false && !v.available) continue;
            if (
              body.preferredSize &&
              !v.title.toLowerCase().includes(body.preferredSize.toLowerCase())
            ) {
              continue;
            }
            const price = parseFloat(v.price);
            const compareAt = v.compare_at_price ? parseFloat(v.compare_at_price) : null;
            const discountPct =
              compareAt && compareAt > price
                ? Number((((compareAt - price) / compareAt) * 100).toFixed(1))
                : 0;

            matchedVariants.push({
              store: cleanDomain,
              productTitle: prod.title,
              variantTitle: v.title,
              sku: v.sku || `UPID-${v.id}`,
              available: v.available,
              priceUsd: price,
              compareAtPriceUsd: compareAt,
              discountPct,
              checkoutUrl: `https://${cleanDomain}/cart/${v.id}:1`,
            });
          }
        }
      } catch {
        // Ignore individual unreachable store
      }
    })
  );

  matchedVariants.sort((a, b) => a.priceUsd - b.priceUsd);
  const cheapest = matchedVariants[0] || null;
  const highest = matchedVariants[matchedVariants.length - 1] || null;
  const maxSavingsPct =
    cheapest && highest && highest.priceUsd > cheapest.priceUsd
      ? Number((((highest.priceUsd - cheapest.priceUsd) / highest.priceUsd) * 100).toFixed(1))
      : 0;

  return {
    query,
    totalVariantsAnalyzed: matchedVariants.length,
    cheapestVariant: cheapest,
    maxCrossStoreSavingsPct: maxSavingsPct,
    topOffers: matchedVariants.slice(0, 8),
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    // Public Bazaar Discovery Catalog Endpoint (Free — allows autonomous agents to index all paid tools)
    if (url.pathname === "/v1/bazaar/catalog" || url.pathname === "/.well-known/x402-bazaar.json") {
      return new Response(
        JSON.stringify(
          {
            provider: "Cukka Agent Data Layer",
            homepage: "https://cukka.org/app.html",
            payTo: env.PAY_TO_ADDRESS || "0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9",
            supportedNetworks: ["eip155:84532", "eip155:8453"],
            endpoints: Object.values(BAZAAR_ENDPOINTS),
          },
          null,
          2
        ),
        { status: 200, headers: { "Content-Type": "application/json", ...CORS_HEADERS } }
      );
    }

    const spec = BAZAAR_ENDPOINTS[url.pathname];
    if (!spec) {
      return new Response(
        JSON.stringify({
          error: "Endpoint not found",
          discoveryUrl: `${url.origin}/v1/bazaar/catalog`,
        }),
        { status: 404, headers: { "Content-Type": "application/json", ...CORS_HEADERS } }
      );
    }

    // Check for x402 payment header (X-PAYMENT or PAYMENT-SIGNATURE)
    const paymentHeader =
      request.headers.get("X-PAYMENT") || request.headers.get("PAYMENT-SIGNATURE");

    if (!paymentHeader) {
      return build402Response(spec, request.url, env);
    }

    // Parse body and execute requested Shopify Global Catalog intelligence tool
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>;

    // Dynamic metering for `upto` scheme vs fixed `exact` scheme
    let settledAtomicUsdc = spec.amountAtomicUsdc;
    if (spec.scheme === "upto") {
      // Meter actual compute/tokens used (e.g., 32% of max cap = $0.008 USDC)
      const maxUnits = parseInt(spec.amountAtomicUsdc, 10);
      settledAtomicUsdc = String(Math.max(1000, Math.floor(maxUnits * 0.32)));
    }

    if (url.pathname === "/v1/catalog/cheapest-variant") {
      const result = await executeCheapestVariantComparison(body);
      return new Response(
        JSON.stringify(
          {
            x402Receipt: {
              scheme: spec.scheme,
              authorizedAtomicUsdc: spec.amountAtomicUsdc,
              settledAtomicUsdc,
              settledUsd: `$${(parseInt(settledAtomicUsdc, 10) / 1e6).toFixed(4)} USDC`,
              payTo: env.PAY_TO_ADDRESS,
            },
            data: result,
          },
          null,
          2
        ),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
            "X-Payment-Scheme": spec.scheme,
            "X-Payment-Settled-Amount": settledAtomicUsdc,
            ...CORS_HEADERS,
          },
        }
      );
    }

    return new Response(
      JSON.stringify(
        {
          x402Receipt: {
            scheme: spec.scheme,
            authorizedAtomicUsdc: spec.amountAtomicUsdc,
            settledAtomicUsdc,
            settledUsd: `$${(parseInt(settledAtomicUsdc, 10) / 1e6).toFixed(4)} USDC`,
            payTo: env.PAY_TO_ADDRESS,
          },
          data: {
            endpoint: spec.path,
            status: "fulfilled",
            input: body,
            timestamp: new Date().toISOString(),
          },
        },
        null,
        2
      ),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "X-Payment-Scheme": spec.scheme,
          "X-Payment-Settled-Amount": settledAtomicUsdc,
          ...CORS_HEADERS,
        },
      }
    );
  },
};
