using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using LobsterInput.Helpers;

namespace LobsterInput.ViewModels;

public sealed partial class OnboardingViewModel : ObservableObject
{
    [ObservableProperty]
    private int _currentStep;

    [ObservableProperty]
    private bool _isComplete;

    [ObservableProperty]
    private string _trialInputText = "";

    [ObservableProperty]
    private string _trialEditableText = "";

    [ObservableProperty]
    private bool _stepTrialDone;

    public int TotalSteps => 9;

    public bool CanGoBack => CurrentStep > 0;

    public bool CanGoNext => CurrentStep switch
    {
        0 => true,
        1 => true,
        8 => true,
        _ => true,
    };

    public bool IsFirstStep => CurrentStep == 0;
    public bool IsLastStep => CurrentStep == TotalSteps - 1;

    public event Action? OnComplete;

    public OnboardingViewModel()
    {
        _trialEditableText = L10n.ObRwEdDefaultText;
    }

    partial void OnCurrentStepChanged(int value)
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(CanGoNext));
        OnPropertyChanged(nameof(IsFirstStep));
        OnPropertyChanged(nameof(IsLastStep));
        StepTrialDone = false;
    }

    [RelayCommand]
    private void Next()
    {
        if (!CanGoNext) return;

        if (CurrentStep < TotalSteps - 1)
        {
            CurrentStep++;
        }
        else
        {
            Complete();
        }
    }

    [RelayCommand]
    private void Back()
    {
        if (CurrentStep > 0)
            CurrentStep--;
    }

    [RelayCommand]
    private void Complete()
    {
        IsComplete = true;
        OnboardingManager.MarkCompleted();
        OnComplete?.Invoke();
        Debug.WriteLine("[Onboarding] Completed");
    }

    [RelayCommand]
    private void SkipToEnd()
    {
        CurrentStep = TotalSteps - 1;
    }

    public void MarkStepTrialDone()
    {
        StepTrialDone = true;
    }
}
