module util;

public static const float EPSILON = 0.0001;
public static const float PI = radians(180.f);
public static const uint MIN_WAVE_SIZE = 32;
public static const uint MAX_UINT = ~0U;
public static const uint MIN_UINT = 0U;
public static const int MAX_INT = (1 << 31) - 1;
public static const int MIN_INT = (1 << 31);

public float4x4 translate(in float3 from, in float3 to) {
  return float4x4(1, 0, 0, to.x - from.x, 0, 1, 0, to.y - from.y, 0, 0, 1, to.z - from.z, 0, 0, 0, 1);
}

public float4x4 rotate(in float3 from, in float3 to) {
  float3 axis = cross(from, to);
  float theta = acos(clamp(dot(from, to), -1.f, 1.f));
  float4x4 eye = {
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  };
  float4x4 a = {
    0, -axis.z, axis.y, 0, axis.z, 0, -axis.x, 0, -axis.y, axis.x, 0, 0, 0, 0, 0, 1,
  };
  return eye + sin(theta) * a + (1 - cos(theta)) * mul(a, a);
}

[vk::constant_id(0)]
public const uint ResponseSampleCount = 0;
[vk::constant_id(1)]
public const uint ElementCount = 0;
[vk::constant_id(2)]
public const uint ScattererCount = 0;
[vk::constant_id(3)]
public const uint ScattererBatchCount = 0;
[vk::constant_id(4)]
public const uint TransmissionCount = 0;
[vk::constant_id(5)]
public const uint ReceiveChannelCount = 0;
[vk::constant_id(6)]
public const uint ApertureSampleCount = 0;
[vk::constant_id(7)]
public const float SamplingFrequency = 0;
[vk::constant_id(8)]
public const float SpeedOfSound = 0;
[vk::constant_id(9)]
public const float StartTime = 0;

public struct Element {
  public float3 position;
  public float4 orientation;
  public float2 size;
  public float apodization;
  public float delay;
}

public struct Scatterer {
  public float3 position;
  public float amplitude;
}

public struct SetMember {
  public uint index;
  public float apodization;
  public float delay;
}

public struct ApertureResponse {
  public float4 rectTimes;
  public float scale;
}

public struct ElementSetInfo {
  public int minSample;
  public int maxSample;
}

// Byte offsets (relative to the start of the data buffer) of each variable-length region.
// These are computed on the CPU since the region lengths depend on runtime values
// (element/scatterer/transmission/receive-channel counts), which specialization constants
// cannot express as static struct member offsets.
public struct DataBufferHeader {
  public uint elementPositions;
  public uint elementOrientations;
  public uint elementSizes;
  public uint elementApodizations;
  public uint elementDelays;
  public uint scatterers;
  public uint apertureResponseRects;
  public uint apertureResponseScales;
  public uint transmissionInfos;
  public uint receiveChannelInfos;
  public uint transmissionResponses;
  public uint receiveChannelResponses;
  public uint transmissionElementCounts;
  public uint transmissionBaseOffsets;
  public uint receiveChannelElementCounts;
  public uint receiveChannelBaseOffsets;
  public uint elementSetMembers;
}

// Reinterprets a byte offset from the header as a pointer to `T`, so each region can be
// addressed independently instead of relying on (unsupported) spec-constant struct offsets.
public T *dataPtr<T>(vk::BufferPointer<DataBufferHeader> dataBuffer, uint byteOffset) { return (T *)((uint64_t)dataBuffer + byteOffset); }

