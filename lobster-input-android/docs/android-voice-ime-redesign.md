# Android Voice IME Redesign

## Product Position

Android is a voice-first input method with an integrated typing keyboard (26-key / 9-grid pinyin + in-keyboard streaming voice). The core loop remains voice-centric; typing mode is a secondary panel inside the same IME.

The core loop is:

1. Speak to insert accurate text.
2. If the inserted or selected text is wrong, speak an instruction to rewrite it.
3. If the last insert was wrong, undo it with one tap or a short voice command.
4. Keep the user in the target text field; do not force them back to the main app for normal correction.

Android does not implement agent mode. The backend route intentionally accepts only `transcribe` and `rewrite`.

## Business Flow

### Transcribe

1. User taps the central microphone.
2. IME records 16 kHz mono WAV.
3. Client uploads to `/api/v1/audio/android/process` with `operation=transcribe`.
4. Backend runs ASR, hotword/vector correction, optional LLM cleanup, and Android prompt routing.
5. IME commits the final `result` into the active input field.
6. The committed result is kept as the fast rewrite target.

### Rewrite

Rewrite target priority:

1. Current selected text in the editor.
2. Last text inserted by Lobster IME.

Flow:

1. User selects text or uses the last inserted text.
2. User taps `Rewrite`.
3. IME records a voice instruction, for example "改成更礼貌一点" or "把这句压缩成一句话".
4. Client uploads with `operation=rewrite` and `selected_text=<target>`.
5. Backend treats voice text as instruction and selected text as object.
6. IME replaces the selected text, or deletes the last inserted text and commits the rewritten result.

This makes correction work like a mature voice input product: speak, inspect, speak a correction.

### Local Voice Controls

Common one-word commands are handled locally after transcription, without new backend operations:

- New line: "换行", "new line", "новая строка", "줄바꿈".
- Backspace: "删除", "退格", "delete", "backspace".
- Undo last Lobster insert: "撤回", "删除刚才", "clear that", "undo".

These commands deliberately affect only the active editor or the last text inserted by Lobster. They do not clear the whole input field, which keeps the behavior recoverable and low risk.

### One-tap Quick Actions

For mobile users, manual selection and voice instructions are expensive. Android therefore exposes quick buttons that process either the current selected text or the last Lobster-inserted text:

- Format: punctuation, paragraphs, and light structure.
- Polish: clearer and more natural wording.
- Shorten: remove repetition and filler while keeping intent.
- Bullets: convert the text into key points or todos.

Client contract:

- `POST /api/v1/text/android/quick-action`
- Body: `{ "action": "format|polish|concise|bullets", "text": "...", "source_operation": "transcribe|rewrite" }`
- Response: a text quick-action response; clients consume `result` as paste text.

Backend behavior:

- Detect the language from the text being processed, not from the client UI language.
- Pick local system prompts through the shared four-platform template layout: `templates/{flow}/{lang}/{platform}/quick_*.txt`.
- Send the target text directly to the LLM with the selected system prompt.
- Do not run ASR vector correction, rewrite tools, or agent routing for quick actions.

## Session Rules

- The main app and IME share the same auth keys in `lobster_input_prefs`.
- Logout removes only auth fields; language and local history remain.
- HTTP 401 or `USER_BANNED` clears auth fields immediately.
- The Compose app observes auth preference changes, so expired sessions return to the login screen.
- The IME observes the same preference state on each UI refresh and blocks recording when logged out.

## Backend Boundary

Android should stay small:

- No OpenClaw.
- No desktop agent routing.
- No search/markdown action surface.
- Keep prompt effort focused on speech accuracy, ASR correction, concise cleanup, and selected-text rewriting.

## Implementation Notes

- `LobsterIME` owns the IME state machine because it has direct access to `InputConnection`.
- `AuthSession` is the shared low-level session helper for IME and app code.
- `NetworkModule.handleResponse()` clears expired sessions for app-side API calls.
- IME upload handling clears expired sessions for service-side audio calls.
