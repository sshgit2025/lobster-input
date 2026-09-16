using System.Diagnostics;
using NAudio.Wave;

namespace LobsterInput.Services.Audio;

public static class AudioPostProcessor
{
    private const int TargetSampleRate = 16000;
    private const int TargetChannels = 1;
    private const int TargetBitDepth = 16;

    public static void ResampleToSpeechWav(string inputPath, string outputPath)
    {
        using var reader = new AudioFileReader(inputPath);

        var targetFormat = new WaveFormat(TargetSampleRate, TargetBitDepth, TargetChannels);

        ISampleProvider pipeline = reader;
        if (reader.WaveFormat.Channels > 1)
            pipeline = pipeline.ToMono();

        pipeline = new SpeechEnhancementSampleProvider(pipeline);

        var waveProvider = pipeline.ToWaveProvider16();

        IWaveProvider finalProvider;
        MediaFoundationResampler? resampler = null;
        if (reader.WaveFormat.SampleRate != TargetSampleRate)
        {
            resampler = new MediaFoundationResampler(waveProvider, targetFormat) { ResamplerQuality = 60 };
            finalProvider = resampler;
        }
        else
        {
            finalProvider = waveProvider;
        }

        try
        {
            WaveFileWriter.CreateWaveFile(outputPath, finalProvider);
            Debug.WriteLine($"[AudioPostProcessor] Encoded to PCM WAV 16kHz mono: {outputPath}");
        }
        finally
        {
            resampler?.Dispose();
        }
    }

    private sealed class SpeechEnhancementSampleProvider(ISampleProvider source) : ISampleProvider
    {
        private float _dcEstimate;
        private float _lastInput;
        private float _smoothedGain = 1f;

        public WaveFormat WaveFormat => source.WaveFormat;

        public int Read(float[] buffer, int offset, int count)
        {
            var read = source.Read(buffer, offset, count);
            for (var i = offset; i < offset + read; i++)
            {
                var sample = buffer[i];
                _dcEstimate = 0.995f * _dcEstimate + 0.005f * sample;
                sample -= _dcEstimate;

                var clarified = sample - 0.94f * _lastInput;
                _lastInput = sample;
                var abs = MathF.Abs(clarified);
                var targetGain = abs < 0.001f ? 1f : Math.Clamp(0.08f / abs, 1f, 8f);
                _smoothedGain = 0.92f * _smoothedGain + 0.08f * targetGain;
                buffer[i] = Math.Clamp(clarified * _smoothedGain, -0.98f, 0.98f);
            }
            return read;
        }
    }
}
