classdef Simulation < handle

    properties
        SimulatorType(1,1) ekhos.SimulatorType = ekhos.SimulatorType.CPU;
        Cumulative(1,1) logical = true;
    end

    properties
        CpuSettings(1,1) ekhos.CpuSettings = ekhos.CpuSettings();
        GpuSettings(1,1) ekhos.GpuSettings = ekhos.GpuSettings();
        HybridSettings(1,1) ekhos.HybridSettings = ekhos.HybridSettings();
        Metrics(1,1) ekhos.SimulatorMetrics = ekhos.SimulatorMetrics();
    end

    properties
        SamplingFrequency(1,1) single = 100e6;
        SpeedOfSound(1,1) single = 1540;
        StartTime(1,1) single = NaN;
        SampleCount(1,1) uint32 = 0;
    end

    properties (Dependent)
        EndTime(1,1) single
    end

    properties
        Elements(1,1) ekhos.RectangularElementSet
        Transmissions(1,1) ekhos.TransmissionSet
        ReceiveChannels(1,1) ekhos.ReceiveChannelSet
        Scatters(1,1) ekhos.ScatterSet
        Impulses(1,:) cell
        Excitations(1,:) cell
    end

    methods
        function pulseEcho = call(simulation)
            arguments
                simulation(1,1) ekhos.Simulation
            end
            ekhos.LoadLibraries();
            pulseEcho = ekhosMex(simulation);
        end
    end

    methods
        function endTime = get.EndTime(simulation)
            endTime = simulation.StartTime + simulation.SampleCount / simulation.SamplingFrequency;
        end
    end
end
