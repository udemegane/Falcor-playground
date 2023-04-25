
// Initial Sampling
static const float prr = P_RR;
static const float invPrr = 1.0 / prr;
static const float prrSecondry = P_SECONDARY_RR;
static const float invPrrSecondry = 1.0 / prrSecondry;
static const bool kUseImportanceSampling = USE_IMPORTANCE_SAMPLING;
static const uint kMaxBounces = MAX_BOUNCES;
static const bool kUseEnvLight = true;
static const bool kUseEmissiveLights = true;
static const bool kUseAnalyticLights = true;

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

static const bool kEvalDirect = EVAL_DIRECT;
static const bool kShowVisibilityPointLi = SHOW_VISIBILITY_POINT_LI;
