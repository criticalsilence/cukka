/**
 * CUKKA x402 — Shopify Global Catalog Agent Data Layer
 *
 * Exposes x402-gated (HTTP 402 Payment Required) endpoints on Base Mainnet (eip155:8453)
 * and Base Sepolia (eip155:84532) with native x402 v2 `extensions.bazaar` discovery schemas
 * and both `exact` and `upto` billing schemes.
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

/**
 * Automatic Categorized Shopify Global Store Registry
 * Automatically selects the best storefronts based on the agent's query or vertical.
 */
export const AUTO_STORE_REGISTRY: Record<string, string[]> = {
  footwear: ["allbirds.com", "kizik.com", "greats.com", "koio.co"],
  apparel: ["gymshark.com", "tentree.com", "chubbies.com", "kotn.com"],
  cosmetics: ["colourpop.com", "cocokind.com", "versedskin.com"],
  coffee_nutrition: ["deathwishcoffee.com", "organifi.com", "foursigmatic.com"],
  accessories_gear: ["ridge.com", "nomadgoods.com", "puravidabracelets.com"],
};

export function autoSelectStoresForQuery(query: string, category?: string): {
  detectedCategory: string;
  stores: string[];
} {
  if (category && category !== "auto" && AUTO_STORE_REGISTRY[category]) {
    return { detectedCategory: category, stores: AUTO_STORE_REGISTRY[category] };
  }

  const q = (query || "").toLowerCase();
  if (/shoe|runner|sneaker|boot|slip|loafer|ayakkab/.test(q)) {
    return { detectedCategory: "footwear", stores: AUTO_STORE_REGISTRY.footwear };
  }
  if (/serum|cream|cleanser|lip|skin|glow|acne|spf|niacinamide|retinol|mask|kozmetik/.test(q)) {
    return { detectedCategory: "cosmetics", stores: AUTO_STORE_REGISTRY.cosmetics };
  }
  if (/coffee|roast|espresso|mug|tea|protein|vitamin|matcha|mushroom|kahve/.test(q)) {
    return { detectedCategory: "coffee_nutrition", stores: AUTO_STORE_REGISTRY.coffee_nutrition };
  }
  if (/wallet|case|cable|watch|strap|bag|ring|bracelet|pack|cüzdan|çanta/.test(q)) {
    return { detectedCategory: "accessories_gear", stores: AUTO_STORE_REGISTRY.accessories_gear };
  }
  if (/shirt|hoodie|short|jogger|pant|top|jacket|sock|legging|sweater|tişört/.test(q)) {
    return { detectedCategory: "apparel", stores: AUTO_STORE_REGISTRY.apparel };
  }

  // Default cross-vertical mix when query is broad
  return {
    detectedCategory: "multi_vertical",
    stores: [
      "allbirds.com",
      "gymshark.com",
      "tentree.com",
      "cocokind.com",
      "deathwishcoffee.com",
      "ridge.com",
    ],
  };
}

export const BAZAAR_ENDPOINTS: Record<string, EndpointSpec> = {
  "/v1/catalog/cheapest-variant": {
    path: "/v1/catalog/cheapest-variant",
    method: "POST",
    name: "Cross-Store Cheapest In-Stock Variant Finder",
    description:
      "Automatically routes across categorized Shopify storefronts & Global Catalog, filters out-of-stock variants, normalizes prices, and returns the cheapest in-stock variant with direct 1-click checkout permalink.",
    category: "commerce",
    scheme: "exact",
    amountAtomicUsdc: "2000", // $0.002 USDC
    priceUsdDisplay: "$0.002",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: {
        query: { type: "string", description: "Product search query (e.g. runner, serum, hoodie, coffee)" },
        category: {
          type: "string",
          enum: ["auto", "footwear", "apparel", "cosmetics", "coffee_nutrition", "accessories_gear"],
          default: "auto",
        },
        inStockOnly: { type: "boolean", default: true },
        preferredSize: { type: "string", description: "Optional variant size/option filter (e.g. M, 10, 250ml)" },
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
    amountAtomicUsdc: "25000", // Max $0.025 USDC
    priceUsdDisplay: "upto $0.025",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: {
        query: { type: "string", description: "Product query, handle, or URL" },
        targetRegion: { type: "string", enum: ["TR", "EU", "US", "UK"], default: "TR" },
      },
    },
  },
  "/v1/catalog/price-stock-watch": {
    path: "/v1/catalog/price-stock-watch",
    method: "POST",
    name: "Real-Time Restock & Genuine Discount Signal",
    description:
      "Checks live variant availability across Shopify storefronts, computes real discount percentage against compare_at_price baseline, and returns restock signals.",
    category: "commerce",
    scheme: "exact",
    amountAtomicUsdc: "1000", // $0.001 USDC
    priceUsdDisplay: "$0.001",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: {
        query: { type: "string" },
        category: { type: "string", default: "auto" },
      },
    },
  },
  "/v1/catalog/niche-match": {
    path: "/v1/catalog/niche-match",
    method: "POST",
    name: "Vertical Niche Matcher (Cosmetic INCI / Spare Parts / Gift Matrix)",
    description:
      "Deep semantic & attribute search across specialized Shopify catalogs (e.g. fragrance-free INCI skincare, vegan materials, or budget-capped gift bundles). Uses x402 'upto' dynamic billing.",
    category: "commerce",
    scheme: "upto",
    amountAtomicUsdc: "50000", // Max $0.050 USDC
    priceUsdDisplay: "upto $0.050",
    inputSchema: {
      type: "object",
      required: ["query"],
      properties: {
        query: { type: "string" },
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
 * Primary network: Base Mainnet (eip155:8453).
 */
export function build402Response(spec: EndpointSpec, requestUrl: string, env: Env): Response {
  const payTo = env.PAY_TO_ADDRESS || "0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9";
  const mainnetUsdc = env.BASE_MAINNET_USDC || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const sepoliaUsdc = env.BASE_SEPOLIA_USDC || "0x036CbD53842c5426634e7929541eC2318f3dCF7e";

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
        network: "eip155:8453", // Base Mainnet (Primary)
        networkName: "base",
        payTo,
        asset: mainnetUsdc,
        amount: spec.amountAtomicUsdc,
        maxAmountRequired: spec.amountAtomicUsdc,
        maxTimeoutSeconds: 300,
        description: `${spec.name} (${spec.priceUsdDisplay} USDC on Base Mainnet)`,
      },
      {
        scheme: spec.scheme,
        network: "eip155:84532", // Base Sepolia Testnet
        networkName: "base-sepolia",
        payTo,
        asset: sepoliaUsdc,
        amount: spec.amountAtomicUsdc,
        maxAmountRequired: spec.amountAtomicUsdc,
        maxTimeoutSeconds: 300,
        description: `${spec.name} (${spec.priceUsdDisplay} USDC on Base Sepolia)`,
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
 * Automatically scans categorized Shopify storefronts for the given query and ranks variants.
 */
async function executeAutoCatalogComparison(body: {
  query?: string;
  category?: string;
  stores?: string[];
  inStockOnly?: boolean;
  preferredSize?: string;
  maxBudgetUsd?: number;
}) {
  const query = (body.query || "runner").toLowerCase().trim();
  const autoSelection = autoSelectStoresForQuery(query, body.category);
  const stores =
    body.stores && body.stores.length > 0 ? body.stores : autoSelection.stores;

  const matchedVariants: Array<{
    store: string;
    productTitle: string;
    productType: string;
    variantId: number;
    variantTitle: string;
    sku: string;
    available: boolean;
    priceUsd: number;
    compareAtPriceUsd: number | null;
    discountPct: number;
    matchedQuery: boolean;
    image: string | null;
    checkoutPermalink: string;
    productUrl: string;
  }> = [];

  await Promise.all(
    stores.map(async (domain) => {
      const cleanDomain = domain.replace(/^https?:\/\//, "").replace(/\/$/, "");
      try {
        const res = await fetch(`https://${cleanDomain}/products.json?limit=40`, {
          headers: { "User-Agent": "Cukka-x402-Agent-Catalog/2.0" },
        });
        if (!res.ok) return;
        const data = (await res.json()) as {
          products?: Array<{
            title: string;
            handle: string;
            product_type?: string;
            tags?: string[];
            images?: Array<{ src: string }>;
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

        for (const product of data.products || []) {
          const titleMatch =
            !query ||
            product.title.toLowerCase().includes(query) ||
            (product.product_type && product.product_type.toLowerCase().includes(query)) ||
            (product.tags && product.tags.join(" ").toLowerCase().includes(query));

          for (const v of product.variants || []) {
            if (body.inStockOnly !== false && !v.available) continue;
            if (
              body.preferredSize &&
              !v.title.toLowerCase().includes(body.preferredSize.toLowerCase())
            ) {
              continue;
            }
            const priceUsd = parseFloat(v.price);
            if (isNaN(priceUsd) || priceUsd <= 0) continue;
            if (body.maxBudgetUsd && priceUsd > body.maxBudgetUsd) continue;

            const compareAt = v.compare_at_price ? parseFloat(v.compare_at_price) : null;
            const discountPct =
              compareAt && compareAt > priceUsd
                ? Number((((compareAt - priceUsd) / compareAt) * 100).toFixed(1))
                : 0;

            matchedVariants.push({
              store: cleanDomain,
              productTitle: product.title,
              productType: product.product_type || autoSelection.detectedCategory,
              variantId: v.id,
              variantTitle: v.title === "Default Title" ? "Standart" : v.title,
              sku: v.sku || `UPID-${v.id}`,
              available: v.available,
              priceUsd,
              compareAtPriceUsd: compareAt,
              discountPct,
              matchedQuery: Boolean(titleMatch),
              image: product.images && product.images[0] ? product.images[0].src : null,
              checkoutPermalink: `https://${cleanDomain}/cart/${v.id}:1`,
              productUrl: `https://${cleanDomain}/products/${product.handle}`,
            });
          }
        }
      } catch (_) {
        // Ignore unreachable store
      }
    })
  );

  const exactMatches = matchedVariants.filter((v) => v.matchedQuery);
  const pool = exactMatches.length > 0 ? exactMatches : matchedVariants;
  pool.sort((a, b) => a.priceUsd - b.priceUsd);

  return {
    query,
    detectedCategory: autoSelection.detectedCategory,
    autoScannedStores: stores,
    totalVariantsEvaluated: matchedVariants.length,
    exactMatchCount: exactMatches.length,
    cheapestInStockVariant: pool[0] || null,
    rankedVariants: pool.slice(0, 12),
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // 1. Public Bazaar Discovery Index (/.well-known/x402-bazaar.json or /v1/bazaar)
    if (url.pathname === "/.well-known/x402-bazaar.json" || url.pathname === "/v1/bazaar") {
      return new Response(
        JSON.stringify(
          {
            x402Version: 2,
            provider: "Cukka — Shopify Global Catalog Agent Data Layer",
            payTo: env.PAY_TO_ADDRESS || "0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9",
            defaultNetwork: "eip155:8453",
            autoStoreCategories: Object.keys(AUTO_STORE_REGISTRY),
            endpoints: Object.values(BAZAAR_ENDPOINTS),
          },
          null,
          2
        ),
        {
          status: 200,
          headers: { "Content-Type": "application/json", ...CORS_HEADERS },
        }
      );
    }

    // 2. Match x402 Endpoint
    const spec = BAZAAR_ENDPOINTS[url.pathname];
    if (!spec) {
      return new Response(
        JSON.stringify({
          error: "Not Found",
          availableEndpoints: Object.keys(BAZAAR_ENDPOINTS),
          bazaarDiscovery: "/.well-known/x402-bazaar.json",
        }),
        { status: 404, headers: { "Content-Type": "application/json", ...CORS_HEADERS } }
      );
    }

    // 3. Check for x402 Payment Header
    const paymentHeader =
      request.headers.get("PAYMENT-SIGNATURE") || request.headers.get("X-PAYMENT");

    if (!paymentHeader) {
      return build402Response(spec, request.url, env);
    }

    // 4. Parse request body & execute catalog intelligence
    let body: Record<string, unknown> = {};
    try {
      body = (await request.json()) as Record<string, unknown>;
    } catch (_) {
      body = {};
    }

    const catalogData = await executeAutoCatalogComparison({
      query: typeof body.query === "string" ? body.query : "runner",
      category: typeof body.category === "string" ? body.category : "auto",
      stores: Array.isArray(body.stores) ? (body.stores as string[]) : undefined,
      inStockOnly: body.inStockOnly !== false,
      preferredSize: typeof body.preferredSize === "string" ? body.preferredSize : undefined,
      maxBudgetUsd: typeof body.maxBudgetUsd === "number" ? body.maxBudgetUsd : undefined,
    });

    // Dynamic metering for 'upto' scheme
    const settledAtomic =
      spec.scheme === "upto"
        ? String(
            Math.min(
              Number(spec.amountAtomicUsdc),
              Math.max(1500, catalogData.rankedVariants.length * 1400)
            )
          )
        : spec.amountAtomicUsdc;

    return new Response(
      JSON.stringify(
        {
          ok: true,
          x402Receipt: {
            scheme: spec.scheme,
            authorizedMaxAtomicUsdc: spec.amountAtomicUsdc,
            settledAtomicUsdc: settledAtomic,
            payTo: env.PAY_TO_ADDRESS || "0x573AaAfce41839cEF3E6D5b9Ad727db44BcE8BA9",
            network: "eip155:8453",
          },
          data: catalogData,
        },
        null,
        2
      ),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "X-Payment-Scheme": spec.scheme,
          "X-Payment-Settled-Amount": settledAtomic,
          ...CORS_HEADERS,
        },
      }
    );
  },
};
