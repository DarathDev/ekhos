classdef HybridSettings
    properties
        CpuScatterFraction(1,1) single {mustBeGreaterThanOrEqual(CpuScatterFraction, 0), mustBeLessThanOrEqual(CpuScatterFraction, 1)} = 0.5;
    end
end
