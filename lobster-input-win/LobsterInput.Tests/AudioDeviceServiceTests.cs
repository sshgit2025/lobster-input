using System.Runtime.InteropServices;
using LobsterInput.Services.Audio;
using Xunit;

namespace LobsterInput.Tests;

public sealed class AudioDeviceServiceTests
{
    [Fact]
    public void IsRecoverableCaptureExceptionTreatsWindowsDeviceInvalidationAsRecoverable()
    {
        var exception = new COMException("device invalidated", unchecked((int)0x88890004));

        Assert.True(AudioDeviceService.IsRecoverableCaptureException(exception));
    }

    [Fact]
    public void IsRecoverableCaptureExceptionTreatsMissingImmDeviceInterfaceAsRecoverable()
    {
        var exception = new InvalidCastException("IMMDevice is unavailable");

        Assert.True(AudioDeviceService.IsRecoverableCaptureException(exception));
    }

    [Fact]
    public void IsRecoverableCaptureExceptionChecksInnerExceptions()
    {
        var exception = new InvalidOperationException(
            "capture failed",
            new COMException("device invalidated", unchecked((int)0x88890004)));

        Assert.True(AudioDeviceService.IsRecoverableCaptureException(exception));
    }
}
