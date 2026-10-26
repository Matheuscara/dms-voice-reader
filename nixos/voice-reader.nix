# Voice reader (dyslexia): select text, press Super+` and Kokoro reads it
# aloud, 100% local. Detects PT (voice pf_dora) or EN (af_heart).
# Super+Shift+` translates the selection (Argos Translate, local) and reads the translation.
# Press again to stop speaking. Keybinds: see README.
# Speed: VOICE_READER_SPEED in the service (1.0 = normal).
{ pkgs, ... }:
let
  py = pkgs.python3.withPackages (p: [
    p.kokoro
    p.langdetect
    p.spacy-models.en_core_web_sm # misaki (English) would download it via uv otherwise
    p.argostranslate # translation models downloaded on first use of each language
  ]);
  voice-reader = pkgs.writeScriptBin "voice-reader"
    ("#!${py}/bin/python\n" + builtins.readFile ./voice-reader/voice-reader.py);
in
{
  environment.systemPackages = [ voice-reader ];

  systemd.user.services.voice-reader = {
    description = "Kokoro voice reader (selected text)";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    path = [ pkgs.wl-clipboard pkgs.pipewire pkgs.libnotify ];
    environment = {
      VOICE_READER_SPEED = "1.0";
      VOICE_READER_TRANSLATE_TO = "pt"; # "pt" or "en"
    };
    serviceConfig = {
      ExecStart = "${voice-reader}/bin/voice-reader daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
