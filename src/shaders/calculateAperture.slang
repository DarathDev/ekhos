module calculateAperture;

import util;

[vk::constant_id(10)]
const uint ElementWorkgroupSize = 64;
[vk::constant_id(11)]
const uint ScattererWorkgroupSize = 1;

struct CalcAperPushData {
  float3 *elementPositions;
  Scatterer *scatterers;
  float4 *apertureResponseRects;
  uint elementOffset;
  uint scattererOffset;

  float4 *getElementOrientations() { return (float4 *)((uint64_t)elementPositions + (uint64_t)ElementCount * sizeof(float3)); }
  float2 *getElementSizes() { return (float2 *)((uint64_t)getElementOrientations() + (uint64_t)ElementCount * sizeof(float4)); }
  float *getElementApodizations() { return (float *)((uint64_t)getElementSizes() + (uint64_t)ElementCount * sizeof(float2)); }
  float *getElementDelays() { return (float *)((uint64_t)getElementApodizations() + (uint64_t)ElementCount * sizeof(float)); }
  float *getApertureResponseScales() {
    return (float *)((uint64_t)apertureResponseRects + (uint64_t)(ElementCount * ScattererBatchCount) * sizeof(float4));
  }
};

[[vk::push_constant]]
ConstantBuffer<CalcAperPushData> pushData;

[shader("compute")]
[numthreads(ElementWorkgroupSize, ScattererWorkgroupSize, 1)]
void main(uint2 GlobalInvocationID: SV_DispatchThreadID, uint threadID: SV_GroupIndex) {
  uint elementIndex = GlobalInvocationID.x;
  uint scattererIndex = GlobalInvocationID.y;

  uint2 dispatchTest = uint2(ElementCount, min(ScattererBatchCount, ScattererCount - pushData.scattererOffset));
  if (any(GlobalInvocationID >= dispatchTest))
    return;

  Element element;
  uint elementInputIndex = elementIndex + pushData.elementOffset;
  element.position = pushData.elementPositions[elementInputIndex];
  element.orientation = pushData.getElementOrientations()[elementInputIndex];
  element.size = pushData.getElementSizes()[elementInputIndex];
  element.apodization = pushData.getElementApodizations()[elementInputIndex];
  element.delay = pushData.getElementDelays()[elementInputIndex];

  uint scattererInputIndex = scattererIndex;
  Scatterer scatterer = pushData.scatterers[scattererInputIndex + pushData.scattererOffset];

  float dt = 1.f / SamplingFrequency;

  ApertureResponse elementResponse = compute_aperture_response(element, scatterer);

  uint apertureOutputIndex = scattererIndex * ElementCount + elementInputIndex;

  pushData.apertureResponseRects[apertureOutputIndex] = elementResponse.rectTimes;
  pushData.getApertureResponseScales()[apertureOutputIndex] = elementResponse.scale;
}

ApertureResponse compute_aperture_response(in Element element, in Scatterer scatterer) {

  float3 scattererRelativePosition = scatterer.position - element.position;
  float3 rotationAxis = -element.orientation.xyz;
  float3 rotationT = 2.f * cross(rotationAxis, scattererRelativePosition);
  scattererRelativePosition = scattererRelativePosition + element.orientation.w * rotationT + cross(rotationAxis, rotationT);
  float2 dieProjection = abs(element.size * scattererRelativePosition.xy);
  float distance = sqrt(dot(scattererRelativePosition, scattererRelativePosition));

  ApertureResponse response;
  // We do not consider scatterers that are to close to the transducer due
  // to a singularity in the response
  if (distance < EPSILON) {
    response.rectTimes = float4(0, 0, 0, 0);
    response.scale = 0;
    return response;
  }

  float t0 = distance / SpeedOfSound;
  float dt1 = min(dieProjection.x, dieProjection.y) / distance / SpeedOfSound;
  float dt2 = max(dieProjection.x, dieProjection.y) / distance / SpeedOfSound;

  float4 rectTimes = t0 + 0.5f * (dt1 * float4(-1, +1, -1, +1) + dt2 * float4(-1, -1, +1, +1));
  response.rectTimes = rectTimes;
  response.rectTimes += element.delay;

  float dt = 1 / SamplingFrequency;
  float denom = (response.rectTimes.w - response.rectTimes.x) * SamplingFrequency <= 1.f ? dt : dt2;
  response.scale = sqrt(scatterer.amplitude) * element.apodization * element.size.x * element.size.y / (2 * PI * distance * denom);
  return response;
}
