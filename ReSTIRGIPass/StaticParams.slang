static const float kRayMax = 1e30f;
static const bool kReadyReflectanceData = READY_REFLECTANCE;
static const bool kUseAnalyticOnlyOnReSTIR = EXCLUDE_ENV_AND_EMISSIVE_FROM_RIS;

// Initial Sampling
static const float prr = P_RR;
static const float invPrr = 1.0 / prr;
static const float prrSecondry = P_SECONDARY_RR;
static const float invPrrSecondry = 1.0 / prrSecondry;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kUseEnvLight = USE_ENVLIGHT;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;

// Temporal Resampling
static const bool kUseTemporalResampling = USE_TEMPORAL_RESAMPLING;
static const uint kTemporalMax = TEMPORAL_RESERVOIR_SIZE;
static const bool kUseInfinitBounce = USE_INFINITE_BOUNCES;

// // Spatial Resampling
static const bool kUseSpatialResampling = USE_SPATIAL_RESAMPLING;
static const uint kSpatialNeigborsNum = SPATIAL_NEIGHBORHOOD_COUNTS;
static const uint kSampleRadius = SPATIAL_RESAMPLING_RADIUS;
static const uint kSpatialMax = SPATIAL_RESERVOIR_SIZE;
static const bool kDoVisibilityTestEverySample = DO_VISIBILITY_TEST_EACH_SAMPLES;

// Debug
static const bool kUseReferencePathTracer = false;
static const bool kEvalDirect = EVAL_DIRECT;
static const bool kShowVisibilityPointLi = SHOW_VISIBILITY_POINT_LI;
static const bool kDebugSplitView = DEBUG_SPLIT_VIEW;

