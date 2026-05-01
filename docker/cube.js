// Default Cube configuration — extend with what you need (security context,
// query rewrites, scheduled refresh, etc.). See https://cube.dev/docs/config.
module.exports = {
  // Compile model from /cube/conf/model
  schemaPath: 'model',

  // Defer all auth to JWT — the chart wires up CUBEJS_JWK_URL/AUDIENCE/ISSUER
  // when cube.jwt.enabled is true.
  // checkAuth: async (req, auth) => { ... },

  // Scheduled refresh contexts (multi-tenant). Return one entry per tenant
  // to refresh; an empty list refreshes the default context.
  // scheduledRefreshContexts: async () => ([{ securityContext: {} }]),

  // Pre-aggregations / orchestrator tuning
  orchestratorOptions: {
    queryCacheOptions: {
      refreshKeyRenewalThreshold: 30,
    },
    preAggregationsOptions: {
      maxPartitions: 10000,
    },
  },
};
