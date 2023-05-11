/***************************************************************************
 # Copyright (c) 2023, udemegane All rights reserved.
 **************************************************************************/

static const bool kUseEnvLight = USE_ENVLIGHT;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseReSTIR = USE_RESTIR;

static const bool kUseTemporalResampling = true;
static const bool kUseSpatialResampling = false;
static const uint kSpatialNeighbors = 8;
static const uint kSampleRadius = 20;
static const bool kUseAllLightSource = false;
static const bool kUseMotionVector = false;
static const uint kRISSampleNums = 8;
static const uint kTemporalMax = 20;
static const uint kSpatialMax = 100;
static const float kRayMax = 1e30f;
