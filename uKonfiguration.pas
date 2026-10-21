unit uKonfiguration;

{$mode objfpc}{$H+}

// ================================================================
// Einlesen/Schreiben der Szenario-Konfiguration (Waermepumpen,
// Gebaeude, Szenario-Zusammensetzung) aus/in einer INI-Datei - das
// ersetzt die frueher direkt im Hauptprogramm hart codierten
// Beispiel-Szenarien und ist die Grundlage fuer eine spaetere GUI
// (die dieselbe Datei lesen/schreiben wuerde).
//
// Format (siehe WriteExampleConfiguration fuer ein vollstaendiges
// Beispiel):
//
//   [Waermepumpe:<Schluessel>]
//   Name=Anzeigename
//   MinTemp=-15
//   MaxFlowTemp=55
//   TWWFlowTemp=50
//   MinModulationAnteil=0.30
//   Heizkurve.FusspunktAussen=21.0
//   Heizkurve.FusspunktVorlauf=25.0
//   Heizkurve.AuslegungAussen=-10.0
//   Heizkurve.AuslegungVorlauf=40.5
//   Kennfeld.AWerte=-15,-7,2,7          (aufsteigend sortiert)
//   Kennfeld.WWerte=35,55               (aufsteigend sortiert)
//   Kennfeld.COP=2.1,1.5,2.7,1.9,...    (zeilenweise je Aussenwert,
//   Kennfeld.Leistung=7.0,6.6,8.5,...    je alle Vorlaufwerte der Reihe nach)
//
//   [Gebaeude:<Schluessel>]
//   Name=Anzeigename
//   HeatLoss=0.25
//   IndoorTemp=21.0
//   TWWDemandDaily=8.0
//   AltWirkungsgrad=0.85
//   AltBrennstoffpreis=0.10
//
//   [Szenario:1]
//   Gebaeude=<Schluessel aus [Gebaeude:...]>
//   Waermepumpen=<Schluessel aus [Waermepumpe:...]>[,<Schluessel2>,...]
//   Name=<optional - nur fuer Kaskaden (>1 Waermepumpe) sinnvoll;
//         sonst gilt automatisch "<WP-Name> / <Gebaeude-Name>">
//
// Mehr als eine Waermepumpe in "Waermepumpen=" (kommagetrennt) ergibt
// automatisch eine Kaskade (TWaermepumpenKaskade) in der Reihenfolge
// der Liste = Zuschaltreihenfolge - siehe uWPTypes.
//
// Jede referenzierte Waermepumpe/jedes Gebaeude wird je Szenario neu
// angelegt (nicht dieselbe Objektinstanz wiederverwendet), damit ein
// und dieselbe [Waermepumpe:...]/[Gebaeude:...]-Definition gefahrlos
// von mehreren Szenarien gleichzeitig referenziert werden kann, ohne
// beim Aufraeumen (.Free) doppelt freigegeben zu werden.
// ================================================================

interface

uses
  SysUtils, Classes, IniFiles, uWPTypes;

// Laedt alle Szenarien aus einer INI-Datei. Liefert False, wenn die
// Datei nicht existiert oder keine [Szenario:N]-Abschnitte enthaelt.
// Bei fehlerhaften Verweisen (unbekanntes Gebaeude/unbekannte
// Waermepumpe, fehlendes/leeres Kennfeld o.ae.) wird eine Exception
// ausgeloest, damit Tippfehler nicht stillschweigend ignoriert werden.
function LoadConfiguration(const FileName: string;
  out Szenarien: TSzenarioKonfigurationArray): Boolean;

// Schreibt die eingebauten vier Beispiel-Szenarien (Bestand/
// teilsaniert/Neubau/Kaskade - dieselben Werte, die frueher direkt im
// Hauptprogramm standen) als INI-Datei, damit das erwartete Format
// sofort ersichtlich ist und als Vorlage fuer eigene Anpassungen
// dient.
procedure WriteExampleConfiguration(const FileName: string);

implementation

type
  TWPParams = record
    Name: string;
    MinTemp, MaxFlowTemp, TWWFlowTemp, MinModulationAnteil: Double;
    Heizkurve: THeizkurve;
    Kennfeld: TKennfeld;
  end;

  TGebaeudeParams = record
    Name: string;
    HeatLoss, IndoorTemp, TWWDemandDaily: Double;
    AltWirkungsgrad, AltBrennstoffpreis: Double;
  end;

  TWPParamsEintrag = record
    Key: string;
    Params: TWPParams;
  end;

  TGebaeudeParamsEintrag = record
    Key: string;
    Params: TGebaeudeParams;
  end;

const
  WPPraefix = 'Waermepumpe:';
  GebPraefix = 'Gebaeude:';
  SzenPraefix = 'Szenario:';

// ----------------------------------------------------------------
// Hilfsfunktionen: kommagetrennte Zahlenlisten <-> TDoubleArray
// ----------------------------------------------------------------

function ParseDoubleListe(const S: string): TDoubleArray;
var
  Teile: TStringList;
  I: Integer;
  FS: TFormatSettings;
  Wert: Double;
  Text: string;
begin
  Teile := TStringList.Create;
  try
    Teile.Delimiter := ',';
    Teile.StrictDelimiter := True;
    Teile.DelimitedText := S;

    SetLength(Result, Teile.Count);
    for I := 0 to Teile.Count - 1 do
    begin
      Text := Trim(Teile[I]);

      FS := DefaultFormatSettings;
      FS.DecimalSeparator := '.';
      if not TryStrToFloat(Text, Wert, FS) then
      begin
        FS.DecimalSeparator := ',';
        if not TryStrToFloat(Text, Wert, FS) then
          raise Exception.CreateFmt(
            'Ungueltige Zahl "%s" in Werteliste "%s".', [Text, S]);
      end;
      Result[I] := Wert;
    end;
  finally
    Teile.Free;
  end;
end;

function DoubleListeToStr(const Werte: array of Double): string;
var
  I: Integer;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := '';
  for I := 0 to High(Werte) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + FormatFloat('0.####', Werte[I], FS);
  end;
end;

// ----------------------------------------------------------------
// Einlesen
// ----------------------------------------------------------------

function LiesWPParams(Ini: TIniFile; const Section, Key: string): TWPParams;
var
  AWerte, WWerte, COPWerte, LeistungWerte: TDoubleArray;
begin
  Result.Name := Ini.ReadString(Section, 'Name', Key);
  Result.MinTemp := Ini.ReadFloat(Section, 'MinTemp', -15.0);
  Result.MaxFlowTemp := Ini.ReadFloat(Section, 'MaxFlowTemp', 55.0);
  Result.TWWFlowTemp := Ini.ReadFloat(Section, 'TWWFlowTemp', 50.0);
  Result.MinModulationAnteil :=
    Ini.ReadFloat(Section, 'MinModulationAnteil', 0.30);

  Result.Heizkurve := MacheHeizkurve(
    Ini.ReadFloat(Section, 'Heizkurve.FusspunktAussen', 15.0),
    Ini.ReadFloat(Section, 'Heizkurve.FusspunktVorlauf', 25.0),
    Ini.ReadFloat(Section, 'Heizkurve.AuslegungAussen', -12.0),
    Ini.ReadFloat(Section, 'Heizkurve.AuslegungVorlauf', 45.0));

  AWerte := ParseDoubleListe(Ini.ReadString(Section, 'Kennfeld.AWerte', ''));
  WWerte := ParseDoubleListe(Ini.ReadString(Section, 'Kennfeld.WWerte', ''));
  COPWerte := ParseDoubleListe(Ini.ReadString(Section, 'Kennfeld.COP', ''));
  LeistungWerte :=
    ParseDoubleListe(Ini.ReadString(Section, 'Kennfeld.Leistung', ''));

  if (Length(AWerte) = 0) or (Length(WWerte) = 0) then
    raise Exception.CreateFmt(
      '[%s]: "Kennfeld.AWerte"/"Kennfeld.WWerte" fehlen oder sind leer.',
      [Section]);

  // MacheKennfeld prueft Laenge/Plausibilitaet und meldet dabei selbst
  // eine aussagekraeftige Exception, falls COP/Leistung nicht zur
  // Rastergroesse passen.
  Result.Kennfeld := MacheKennfeld(AWerte, WWerte, COPWerte, LeistungWerte);
end;

function LiesGebaeudeParams(Ini: TIniFile;
  const Section, Key: string): TGebaeudeParams;
begin
  Result.Name := Ini.ReadString(Section, 'Name', Key);
  Result.HeatLoss := Ini.ReadFloat(Section, 'HeatLoss', 0.2);
  Result.IndoorTemp := Ini.ReadFloat(Section, 'IndoorTemp', 21.0);
  Result.TWWDemandDaily := Ini.ReadFloat(Section, 'TWWDemandDaily', 8.0);
  Result.AltWirkungsgrad := Ini.ReadFloat(Section, 'AltWirkungsgrad', 0.90);
  Result.AltBrennstoffpreis :=
    Ini.ReadFloat(Section, 'AltBrennstoffpreis', 0.10);
end;

function ErzeugeWaermepumpe(const P: TWPParams): TWaermepumpe;
begin
  Result := TWaermepumpe.Create(P.Name, P.MinTemp, P.MaxFlowTemp,
    P.TWWFlowTemp, P.MinModulationAnteil, P.Heizkurve, P.Kennfeld);
end;

function ErzeugeGebaeude(const P: TGebaeudeParams): TGebaeude;
begin
  Result := TGebaeude.Create(P.Name, P.HeatLoss, P.IndoorTemp,
    P.TWWDemandDaily, P.AltWirkungsgrad, P.AltBrennstoffpreis);
end;

function FindWPParams(const Liste: array of TWPParamsEintrag;
  const Key: string; out Params: TWPParams): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Liste) do
    if SameText(Liste[I].Key, Key) then
    begin
      Params := Liste[I].Params;
      Exit(True);
    end;
  Result := False;
end;

function FindGebaeudeParams(const Liste: array of TGebaeudeParamsEintrag;
  const Key: string; out Params: TGebaeudeParams): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(Liste) do
    if SameText(Liste[I].Key, Key) then
    begin
      Params := Liste[I].Params;
      Exit(True);
    end;
  Result := False;
end;

function LoadConfiguration(const FileName: string;
  out Szenarien: TSzenarioKonfigurationArray): Boolean;
var
  Ini: TIniFile;
  Sections: TStringList;
  WPParamsListe: array of TWPParamsEintrag;
  GebParamsListe: array of TGebaeudeParamsEintrag;
  I, J, NWP, NGeb, NSzen, Tausch: Integer;
  SectionName, Key, GebKey: string;
  SzenarioNummern: array of Integer;
  WPNamenListe: TStringList;
  Einheiten: array of TWaermepumpe;
  WPParams: TWPParams;
  GebParams: TGebaeudeParams;
  KaskadenName: string;
begin
  Result := False;
  SetLength(Szenarien, 0);

  if not FileExists(FileName) then
    Exit;

  Ini := TIniFile.Create(FileName);
  Sections := TStringList.Create;
  WPNamenListe := TStringList.Create;
  try
    Ini.ReadSections(Sections);

    // -- Pass 1: Waermepumpen-Parameter einlesen --------------------
    NWP := 0;
    SetLength(WPParamsListe, Sections.Count);
    for I := 0 to Sections.Count - 1 do
    begin
      SectionName := Sections[I];
      if Pos(WPPraefix, SectionName) = 1 then
      begin
        Key := Copy(SectionName, Length(WPPraefix) + 1, MaxInt);
        WPParamsListe[NWP].Key := Key;
        WPParamsListe[NWP].Params := LiesWPParams(Ini, SectionName, Key);
        Inc(NWP);
      end;
    end;
    SetLength(WPParamsListe, NWP);

    // -- Pass 2: Gebaeude-Parameter einlesen -------------------------
    NGeb := 0;
    SetLength(GebParamsListe, Sections.Count);
    for I := 0 to Sections.Count - 1 do
    begin
      SectionName := Sections[I];
      if Pos(GebPraefix, SectionName) = 1 then
      begin
        Key := Copy(SectionName, Length(GebPraefix) + 1, MaxInt);
        GebParamsListe[NGeb].Key := Key;
        GebParamsListe[NGeb].Params := LiesGebaeudeParams(Ini, SectionName, Key);
        Inc(NGeb);
      end;
    end;
    SetLength(GebParamsListe, NGeb);

    // -- Pass 3: Szenario-Nummern einsammeln und sortieren -----------
    SetLength(SzenarioNummern, 0);
    for I := 0 to Sections.Count - 1 do
      if Pos(SzenPraefix, Sections[I]) = 1 then
      begin
        SetLength(SzenarioNummern, Length(SzenarioNummern) + 1);
        SzenarioNummern[High(SzenarioNummern)] :=
          StrToIntDef(Copy(Sections[I], Length(SzenPraefix) + 1, MaxInt), 0);
      end;

    // einfacher Bubble-Sort - wenige Szenarien, Lesbarkeit vor Tempo.
    for I := 0 to High(SzenarioNummern) - 1 do
      for J := 0 to High(SzenarioNummern) - I - 1 do
        if SzenarioNummern[J] > SzenarioNummern[J + 1] then
        begin
          Tausch := SzenarioNummern[J];
          SzenarioNummern[J] := SzenarioNummern[J + 1];
          SzenarioNummern[J + 1] := Tausch;
        end;

    // -- Pass 4: Szenarien zusammenbauen ------------------------------
    NSzen := 0;
    SetLength(Szenarien, Length(SzenarioNummern));
    for I := 0 to High(SzenarioNummern) do
    begin
      SectionName := Format('%s%d', [SzenPraefix, SzenarioNummern[I]]);

      GebKey := Ini.ReadString(SectionName, 'Gebaeude', '');
      if not FindGebaeudeParams(GebParamsListe, GebKey, GebParams) then
        raise Exception.CreateFmt(
          '[%s]: unbekanntes Gebaeude "%s" in "Gebaeude=".',
          [SectionName, GebKey]);

      WPNamenListe.CommaText := Ini.ReadString(SectionName, 'Waermepumpen', '');
      if WPNamenListe.Count < 1 then
        raise Exception.CreateFmt(
          '[%s]: mindestens eine Waermepumpe in "Waermepumpen=" noetig.',
          [SectionName]);

      SetLength(Einheiten, WPNamenListe.Count);
      for J := 0 to WPNamenListe.Count - 1 do
      begin
        if not FindWPParams(WPParamsListe, Trim(WPNamenListe[J]), WPParams) then
          raise Exception.CreateFmt(
            '[%s]: unbekannte Waermepumpe "%s" in "Waermepumpen=".',
            [SectionName, Trim(WPNamenListe[J])]);
        Einheiten[J] := ErzeugeWaermepumpe(WPParams);
      end;

      Szenarien[NSzen].Gebaeude := ErzeugeGebaeude(GebParams);

      if Length(Einheiten) = 1 then
        Szenarien[NSzen].WP := Einheiten[0]
      else
      begin
        KaskadenName := Ini.ReadString(SectionName, 'Name', '');
        if KaskadenName = '' then
        begin
          KaskadenName := 'Kaskade (' + Trim(WPNamenListe[0]);
          for J := 1 to WPNamenListe.Count - 1 do
            KaskadenName := KaskadenName + '+' + Trim(WPNamenListe[J]);
          KaskadenName := KaskadenName + ')';
        end;
        Szenarien[NSzen].WP :=
          TWaermepumpenKaskade.Create(KaskadenName, Einheiten);
      end;

      Inc(NSzen);
    end;

    SetLength(Szenarien, NSzen);
    Result := NSzen > 0;
  finally
    WPNamenListe.Free;
    Sections.Free;
    Ini.Free;
  end;
end;

// ----------------------------------------------------------------
// Schreiben der Beispiel-Konfiguration
// ----------------------------------------------------------------

procedure WriteExampleConfiguration(const FileName: string);
var
  Ini: TIniFile;

  procedure SchreibeWP(const Section, Name: string;
    MinTemp, MaxFlowTemp, TWWFlowTemp, MinModulationAnteil: Double;
    const Heizkurve: THeizkurve;
    const AWerte, WWerte, COPWerte, LeistungWerte: array of Double);
  begin
    Ini.WriteString(Section, 'Name', Name);
    Ini.WriteFloat(Section, 'MinTemp', MinTemp);
    Ini.WriteFloat(Section, 'MaxFlowTemp', MaxFlowTemp);
    Ini.WriteFloat(Section, 'TWWFlowTemp', TWWFlowTemp);
    Ini.WriteFloat(Section, 'MinModulationAnteil', MinModulationAnteil);
    Ini.WriteFloat(Section, 'Heizkurve.FusspunktAussen',
      Heizkurve.FusspunktAussen);
    Ini.WriteFloat(Section, 'Heizkurve.FusspunktVorlauf',
      Heizkurve.FusspunktVorlauf);
    Ini.WriteFloat(Section, 'Heizkurve.AuslegungAussen',
      Heizkurve.AuslegungAussen);
    Ini.WriteFloat(Section, 'Heizkurve.AuslegungVorlauf',
      Heizkurve.AuslegungVorlauf);
    Ini.WriteString(Section, 'Kennfeld.AWerte', DoubleListeToStr(AWerte));
    Ini.WriteString(Section, 'Kennfeld.WWerte', DoubleListeToStr(WWerte));
    Ini.WriteString(Section, 'Kennfeld.COP', DoubleListeToStr(COPWerte));
    Ini.WriteString(Section, 'Kennfeld.Leistung',
      DoubleListeToStr(LeistungWerte));
  end;

  procedure SchreibeGebaeude(const Section, Name: string;
    HeatLoss, IndoorTemp, TWWDemandDaily,
    AltWirkungsgrad, AltBrennstoffpreis: Double);
  begin
    Ini.WriteString(Section, 'Name', Name);
    Ini.WriteFloat(Section, 'HeatLoss', HeatLoss);
    Ini.WriteFloat(Section, 'IndoorTemp', IndoorTemp);
    Ini.WriteFloat(Section, 'TWWDemandDaily', TWWDemandDaily);
    Ini.WriteFloat(Section, 'AltWirkungsgrad', AltWirkungsgrad);
    Ini.WriteFloat(Section, 'AltBrennstoffpreis', AltBrennstoffpreis);
  end;

begin
  if FileExists(FileName) then
    DeleteFile(FileName);  // sauber neu schreiben, keine Altlasten

  Ini := TIniFile.Create(FileName);
  try
    // -- Szenario 1: Bestandsgebaeude, WP der 10-kW-Klasse ------------
    SchreibeWP(WPPraefix + 'WP_Bestand_10kW', 'WP 10kW (Bestand)',
      -15.0, 55.0, 50.0, 0.30,
      MacheHeizkurve(21.0, 25.0, -10.0, 40.5),
      [-15.0, -7.0, 2.0, 7.0], [35.0, 55.0],
      [2.1, 1.5, 2.7, 1.9, 3.7, 2.6, 4.7, 3.2],
      [7.0, 6.6, 8.5, 8.0, 10.0, 9.5, 10.8, 10.3]);
    SchreibeGebaeude(GebPraefix + 'Bestand_Heizkoerper',
      'Bestandsgebaeude, Heizkoerper', 0.25, 21.0, 8.0, 0.85, 0.10);
    Ini.WriteString(SzenPraefix + '1', 'Gebaeude', 'Bestand_Heizkoerper');
    Ini.WriteString(SzenPraefix + '1', 'Waermepumpen', 'WP_Bestand_10kW');

    // -- Szenario 2: teilsanierter Altbau, WP der 8-kW-Klasse ---------
    SchreibeWP(WPPraefix + 'WP_Effizient_8kW', 'WP 8kW (effizienter)',
      -15.0, 60.0, 50.0, 0.30,
      MacheHeizkurve(18.0, 24.0, -12.0, 40.0),
      [-7.0, 2.0, 7.0], [35.0, 55.0],
      [3.0, 2.1, 4.0, 2.8, 5.0, 3.5],
      [6.8, 6.4, 8.0, 7.6, 8.6, 8.2]);
    SchreibeGebaeude(GebPraefix + 'Teilsanierter_Altbau',
      'Teilsanierter Altbau', 0.18, 21.0, 8.0, 0.92, 0.10);
    Ini.WriteString(SzenPraefix + '2', 'Gebaeude', 'Teilsanierter_Altbau');
    Ini.WriteString(SzenPraefix + '2', 'Waermepumpen', 'WP_Effizient_8kW');

    // -- Szenario 3: Neubau/FBH, WP der 6-kW-Klasse -------------------
    SchreibeWP(WPPraefix + 'WP_Neubau_6kW', 'WP 6kW (Neubau, FBH)',
      -15.0, 45.0, 50.0, 0.25,
      MacheHeizkurve(15.0, 22.0, -12.0, 33.0),
      [-7.0, 2.0, 7.0], [35.0, 45.0, 55.0],
      [3.2, 2.7, 2.3, 4.3, 3.6, 3.0, 5.4, 4.4, 3.7],
      [5.2, 5.0, 4.9, 6.0, 5.9, 5.7, 6.4, 6.3, 6.1]);
    SchreibeGebaeude(GebPraefix + 'Neubau_FBH',
      'Neubau, Fussbodenheizung', 0.12, 21.0, 8.0, 0.92, 0.10);
    Ini.WriteString(SzenPraefix + '3', 'Gebaeude', 'Neubau_FBH');
    Ini.WriteString(SzenPraefix + '3', 'Waermepumpen', 'WP_Neubau_6kW');

    // -- Szenario 4: Kaskade aus zwei Einheiten (Mehrfamilienhaus) ----
    SchreibeWP(WPPraefix + 'Kaskade_Einheit_A',
      'Kaskade-Einheit A (6kW, Fuehrung)',
      -15.0, 55.0, 50.0, 0.25,
      MacheHeizkurve(18.0, 25.0, -12.0, 45.0),
      [-7.0, 2.0, 7.0], [35.0, 55.0],
      [3.1, 2.2, 4.2, 2.9, 5.2, 3.6],
      [5.6, 5.3, 6.2, 5.9, 6.6, 6.3]);
    SchreibeWP(WPPraefix + 'Kaskade_Einheit_B',
      'Kaskade-Einheit B (10kW, Spitzenlast)',
      -15.0, 55.0, 50.0, 0.45,
      MacheHeizkurve(18.0, 25.0, -12.0, 45.0),
      [-15.0, -7.0, 2.0, 7.0], [35.0, 55.0],
      [2.1, 1.5, 2.7, 1.9, 3.7, 2.6, 4.7, 3.2],
      [7.0, 6.6, 8.5, 8.0, 10.0, 9.5, 10.8, 10.3]);
    SchreibeGebaeude(GebPraefix + 'Mehrfamilienhaus_Kaskade',
      'Mehrfamilienhaus (Bestand, Kaskade)', 0.55, 20.0, 35.0, 0.85, 0.10);
    Ini.WriteString(SzenPraefix + '4', 'Name',
      'Kaskade 6+10 kW (Mehrfamilienhaus)');
    Ini.WriteString(SzenPraefix + '4', 'Gebaeude', 'Mehrfamilienhaus_Kaskade');
    Ini.WriteString(SzenPraefix + '4', 'Waermepumpen',
      'Kaskade_Einheit_A,Kaskade_Einheit_B');
  finally
    Ini.UpdateFile;
    Ini.Free;
  end;
end;

end.
