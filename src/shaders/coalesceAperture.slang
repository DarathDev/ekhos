module coalesceAperture;

import util;
import coalesceUtil;

[vk::constant_id(12)]
const uint SampleWorkgroupSize = 64;
[vk::constant_id(13)]
const uint ElementSetWorkgroupSize = 1;
[vk::constant_id(14)]
const uint ScattererWorkgroupSize = 1;

[shader("compute")]
[numthreads(SampleWorkgroupSize, ElementSetWorkgroupSize, ScattererWorkgroupSize)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID) {
  uint sampleIndex = GlobalInvocationID.x + pushData.sampleOffset;
  uint elementSetIndex = GlobalInvocationID.y + pushData.elementSetOffset;
  uint scattererIndex = GlobalInvocationID.z;

  uint ElementSetCount = CoalesceTransmissions ? TransmissionCount : ReceiveChannelCount;

  uint3 dispatchTest = uint3(ApertureSampleCount, ElementSetCount, ScattererCount - pushData.scattererOffset);
  if (any(GlobalInvocationID >= dispatchTest))
    return;

  uint elementSetInfoIndex = scattererIndex * ElementSetCount + elementSetIndex;
  ElementSetInfo elementSetInfo =
      CoalesceTransmissions ? pushData.transmissionInfos[elementSetInfoIndex] : pushData.getReceiveChannelInfos()[elementSetInfoIndex];

  uint sampleOutputIndex = scattererIndex * (ApertureSampleCount * ElementSetCount) + elementSetIndex * ApertureSampleCount + sampleIndex;
  int supportSampleCount = elementSetInfo.maxSample - elementSetInfo.minSample;
  if (elementSetInfo.minSample > elementSetInfo.maxSample || sampleIndex > uint(min(int(ApertureSampleCount) - 1, supportSampleCount))) {
    if (CoalesceTransmissions) {
      pushData.transmissionResponses[sampleOutputIndex] = 0;
    } else {
      pushData.getReceiveChannelResponses()[sampleOutputIndex] = 0;
    }
    return;
  }

  float dt = 1.f / SamplingFrequency;
  // We need to offset by the start time once
  float timeOffset = CoalesceTransmissions ? 0 : -StartTime;

  float sampleSum = 0;
  uint memberCount = pushData.getMemberCount(elementSetIndex);
  uint memberBaseOffset = CoalesceTransmissions ? pushData.getTransmissionBaseOffsets()[elementSetIndex]
                                                : pushData.getReceiveChannelBaseOffsets()[elementSetIndex];
  for (uint memberIndex = 0; memberIndex < memberCount; memberIndex++) {
    SetMember member;
    member.index = pushData.elementSetMembers[memberBaseOffset + memberIndex];
    member.apodization = ((float *)pushData.elementSetMembers)[memberBaseOffset + memberCount + memberIndex];
    member.delay = ((float *)pushData.elementSetMembers)[memberBaseOffset + 2 * memberCount + memberIndex];

    ApertureResponse memberResponse = getResponse(member, scattererIndex, dt);
    if (memberResponse.scale == 0)
      continue;

    memberResponse.rectTimes += timeOffset;

    float4 rectSamples = memberResponse.rectTimes * SamplingFrequency - elementSetInfo.minSample;

    float sample = sample_rect_aperture(sampleIndex, rectSamples);
    sampleSum += sample * memberResponse.scale;
  }

  if (CoalesceTransmissions) {
    pushData.transmissionResponses[sampleOutputIndex] = sampleSum;
  } else {
    pushData.getReceiveChannelResponses()[sampleOutputIndex] = sampleSum;
  }
}

float sample_rect_aperture(in int i, in float4 nRectT) {
  if (Cumulative) {
    return sample_rect_aperture_cumulative(i, nRectT) - sample_rect_aperture_cumulative(i - 1, nRectT);
  } else {
    return sample_rect_aperture_discrete(i, nRectT);
  }
}

float sample_rect_aperture_cumulative(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1.f;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= EPSILON);
  bool qTri = !qDelta && !qRect && (rectSamples.z - rectSamples.y <= EPSILON);

  if (qDelta)
    return n >= rectSamples.x ? 1 : 0;

  if (qRect) {
    float dy = rectSamples.z - rectSamples.y;
    return dy <= 0.f ? 0.0f : dy * saturate((n - rectSamples.y) / dy);
  }

  float dxLeft = rectSamples.y - rectSamples.x;
  float sTriLeftSat = dxLeft <= 0.f ? 0.0f : saturate((n - rectSamples.x) / dxLeft);
  float sTriLeft = 0.5f * dxLeft * sTriLeftSat * sTriLeftSat;

  float dxRight = rectSamples.w - rectSamples.z;
  float sTriRightSat = dxRight <= 0.f ? 0.0f : saturate((rectSamples.w - n) / dxRight);
  float sTriRight = 0.5f * dxRight * (1.f - sTriRightSat * sTriRightSat);

  if (qTri)
    return sTriLeft + sTriRight;

  float dy = rectSamples.z - rectSamples.y;
  float sRect = dy <= 0.f ? 0.0f : dy * saturate((n - rectSamples.y) / dy);
  return sTriLeft + sRect + sTriRight;
}

float sample_rect_aperture_discrete(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1.f;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= EPSILON);
  bool qTri = !qDelta && !qRect && (rectSamples.z - rectSamples.y <= EPSILON);

  if (qDelta)
    return saturate(1.f - abs(n - rectSamples.x));

  if (qRect) {
    bool left = (n >= rectSamples.y - 0.5f) & (n <= rectSamples.y + 0.5f);
    bool center = (n > rectSamples.y + 0.5f) & (n <= rectSamples.z - 0.5f);
    bool right = (n > rectSamples.z - 0.5f) & (n <= rectSamples.z + 0.5f);
    float leftValue = n - (rectSamples.y - 0.5f);
    float rightValue = 1.f - (n - (rectSamples.z - 0.5f));
    return saturate((left ? leftValue : 0) + (center ? 1.f : 0) + (right ? rightValue : 0));
  }

  float sTriLeft = (n - rectSamples.x) / (rectSamples.y - rectSamples.x + EPSILON);
  float sTriRight = (1.f - (n - rectSamples.z) / (rectSamples.w - rectSamples.z + EPSILON));

  bool left = (n >= rectSamples.x) & (n <= rectSamples.y);
  bool right = (n > rectSamples.z) & (n <= rectSamples.w);
  if (qTri)
    return saturate((left ? sTriLeft : 0) + (right ? sTriRight : 0));

  bool center = (n > rectSamples.y) & (n <= rectSamples.z);
  return saturate((left ? sTriLeft : 0) + (center ? 1.f : 0) + (right ? sTriRight : 0));
}
