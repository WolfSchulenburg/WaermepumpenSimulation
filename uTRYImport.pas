{ ============================================================================
  uTRYImport.pas

  Import echter Stundenwetterdaten aus einer DWD-TRY-Datei (Testreferenz-
  jahr): Temperatur, Wind, Luftfeuchte, direkte/diffuse Sonnenstrahlung auf
  der Horizontalen sowie atmosphärische/terrestrische Wärmestrahlung, je
  eine Zeile pro Stunde eines Jahres.

  Basiert auf den vom Nutzer bereitgestellten Dateien pWeatherRecord.pas und
  pImportRefYear.pas. Deren Datenfelder und - wichtig - deren Spaltenzuord-
  nung beim Einlesen (welcher Tokenindex zu welcher physikalischen Größe
  gehört) wurden unverändert übernommen, da sie vermutlich gegen echte
  TRY-Dateien entwickelt/geprüft wurden und hier nicht ohne eine solche
  Referenzdatei nachvollzogen werden können.

  Was gegenüber der Vorlage geändert wurde (rein technisch, keine andere
  Spaltenzuordnung):

  - "System.Classes"/"System.SysUtils"/"System.DateUtils" -> "Classes"/
    "SysUtils"/"DateUtils" (Unit-Scopes, wie im übrigen Projekt).
  - Kein globaler Zustand mehr (var ReferenceYear: TReferenceYear). Statt-
    dessen liefert LoadTRYYear() einen eigenständigen TTRYYear-Record
    zurück - notwendig, damit z. B. Analyse.lpr mehrere Gebäude mit
    unterschiedlichen TRY-Dateien in einem Programmlauf verarbeiten kann,
    ohne dass sich die Importe gegenseitig überschreiben.
  - Spaltentrennung per Whitespace-Tokenizer (SplitWhitespace) statt
    TStrings.DelimitedText mit dem (in der Vorlage nie geänderten)
    Standard-Trennzeichen ','. Echte TRY-Dateien sind durch eine wechselnde
    Anzahl Leerzeichen spaltenausgerichtet, nicht durch Kommas.
  - Fehler beim Einlesen brechen den Import nicht mehr ab (kein
    unbehandeltes StrToInt/StrToFloat), sondern werden - wie beim Rest des
    Projekts (siehe uBuildingDescription.pas) - als Text in einer
    Warnings-Liste gesammelt; nicht lesbare/fehlende Stunden bleiben auf 0
    (mit Warnung), statt das ganze Programm abzubrechen.
  - HourOfTheYear() (in der Vorlage vorausgesetzt, aber nicht Teil des
    FPC-DateUtils) selbst implementiert, 0-basiert (0..8759), passend zu
    einem 0-basierten Array.
  - ConvertReal() ersetzt durch eine Variante mit expliziten
    FormatSettings (wie ParseFloat in uBuildingDescription.pas), damit das
    Ergebnis nicht von der Systemspracheinstellung abhängt.
  ============================================================================ }
unit uTRYImport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils;

const
  HoursPerYear = 8760;

  { Mindestanzahl Spalten einer Datenzeile (Tokenindizes 0..17 werden
    gebraucht, teils übersprungen - siehe LoadTRYYear). }
  MinDataColumns = 18;

type
  TTRYRecord = record
    Time: TDateTime;
    Month, Day, Hour: Integer;

    Filled: Boolean; // True, wenn diese Stunde tatsächlich aus der Datei gelesen wurde

    Cloudiness: Integer;       // N  Bedeckungsgrad [Achtel]
    WindDirection: Integer;    // WR Windrichtung in 10 m Höhe über Grund [°]
    WindSpeed: Double;         // WG Windgeschwindigkeit in 10 m Höhe über Grund [m/s]

    Temperature: Double;       // t  Lufttemperatur in 2 m Höhe über Grund [°C]
    Pressure: Double;          // p  Luftdruck in Stationshöhe [hPa]

    AbsHumidity: Double;       // x  Wasserdampfgehalt, Mischungsverhältnis [g/kg]
    RelHumidity: Double;       // RF Relative Feuchte in 2 m Höhe über Grund [%]

    DirectSunPowerHorizontal: Double;  // B  Direkte Sonnenbestrahlungsstärke (horiz.) [W/m²]
    DiffuseSunPowerHorizontal: Double; // D  Diffuse Sonnenbestrahlungsstärke (horiz.) [W/m²]

    AtmIrradianceHorizontal: Double;   // A  Bestrahlungsstärke atm. Wärmestrahlung (horiz.) [W/m²]
    TerrIrradianceHorizontal: Double;  // E  Bestrahlungsstärke terr. Wärmestrahlung [W/m²]
  end;

  { TTRYYear - ein vollständiges (0..HoursPerYear-1) Stundenraster eines
    Jahres. FilledHours < HoursPerYear zeigt an, dass nicht jede Stunde aus
    der Datei gelesen werden konnte (fehlende Stunden bleiben auf 0). }
  TTRYYear = record
    Year: Integer;
    SourceFileName: string;
    HourlyRecords: array of TTRYRecord; // Länge HoursPerYear, Index = HourIndexOfYear
    FilledHours: Integer;
  end;

{ 0-basierter Stundenindex des Jahres (0..8759) für einen Zeitpunkt - Index
  in TTRYYear.HourlyRecords. }
function HourIndexOfYear(const DateTime: TDateTime): Integer;

{ Lädt eine TRY-Datei. Liefert in TRYYear immer ein vollständig
  dimensioniertes Jahresraster zurück (bei Problemen ggf. teilweise oder
  komplett mit Nullen gefüllt) und gibt True zurück, wenn zumindest ein
  Teil der Stunden gelesen werden konnte. Probleme werden - wie beim Rest
  des Projekts - als Text an Warnings angehängt (falls übergeben, darf
  nil sein), statt das Programm abzubrechen. }
function LoadTRYYear(const FileName: string; out TRYYear: TTRYYear;
  Warnings: TStringList): Boolean;

{ Mittelwert der Stundentemperaturen über alle tatsächlich gefüllten
  Stunden - eine aus echten Daten abgeleitete, deutlich belastbarere
  Alternative zur von Hand geschätzten Standort-Jahresmitteltemperatur
  (siehe uBuildingDescription.TBuildingDescription.SiteAnnualMeanTemperature). }
function AverageTemperature(const TRYYear: TTRYYear): Double;

{ Liefert den Stundendatensatz zu HourIndex, oder einen Nullrekord, falls
  der Index außerhalb des Jahres liegt (kein Bereichsfehler). }
function GetTRYRecord(const TRYYear: TTRYYear; HourIndex: Integer): TTRYRecord;

implementation

function HourIndexOfYear(const DateTime: TDateTime): Integer;
begin
  Result := (DayOfTheYear(DateTime) - 1) * 24 + HourOf(DateTime);
end;

function GetTRYRecord(const TRYYear: TTRYYear; HourIndex: Integer): TTRYRecord;
begin
  if (HourIndex >= 0) and (HourIndex < Length(TRYYear.HourlyRecords)) then
    Result := TRYYear.HourlyRecords[HourIndex]
  else
    FillChar(Result, SizeOf(Result), 0);
end;

function AverageTemperature(const TRYYear: TTRYYear): Double;
var
  I: Integer;
  Sum: Double;
  N: Integer;
begin
  Sum := 0;
  N := 0;
  for I := 0 to High(TRYYear.HourlyRecords) do
    if TRYYear.HourlyRecords[I].Filled then
    begin
      Sum := Sum + TRYYear.HourlyRecords[I].Temperature;
      Inc(N);
    end;

  if N > 0 then
    Result := Sum / N
  else
    Result := 0;
end;

{ Zerlegt S an einer beliebigen Folge von Leerzeichen/Tabs in Tokens - im
  Gegensatz zu TStrings.DelimitedText (Standard-Trennzeichen ',') geeignet
  für spaltenausgerichtete TRY-Textdateien. }
procedure SplitWhitespace(const S: string; Tokens: TStrings);
var
  I, Len, StartPos: Integer;
begin
  Tokens.Clear;
  Len := Length(S);
  I := 1;
  while I <= Len do
  begin
    while (I <= Len) and (S[I] in [' ', #9]) do
      Inc(I);
    if I > Len then
      Break;

    StartPos := I;
    while (I <= Len) and not (S[I] in [' ', #9]) do
      Inc(I);

    Tokens.Add(Copy(S, StartPos, I - StartPos));
  end;
end;

{ Wie ParseFloat in uBuildingDescription.pas: akzeptiert '.' und ',' als
  Dezimaltrennzeichen, unabhängig von der Systemspracheinstellung. }
function TryParseNumber(const S: string; out Value: Double): Boolean;
var
  Cleaned: string;
  FS: TFormatSettings;
begin
  Cleaned := StringReplace(Trim(S), ',', '.', [rfReplaceAll]);

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;

  Result := TryStrToFloat(Cleaned, Value, FS);
end;

function LoadTRYYear(const FileName: string; out TRYYear: TTRYYear;
  Warnings: TStringList): Boolean;

  procedure Warn(const Msg: string);
  begin
    if Warnings <> nil then
      Warnings.Add(Msg);
  end;

var
  Lines: TStringList;
  Tokens: TStringList;
  I, LineNo: Integer;
  StartMarkerFound: Boolean;
  YearFromName: string;
  iMonth, iDay, iHour: Integer;
  iTime: TDateTime;
  HourIndex: Integer;
  ParseOK: Boolean;

  function ReadInt(Idx: Integer; out V: Integer): Boolean;
  begin
    Result := (Idx < Tokens.Count) and TryStrToInt(Trim(Tokens[Idx]), V);
  end;

  function ReadReal(Idx: Integer; out V: Double): Boolean;
  begin
    Result := (Idx < Tokens.Count) and TryParseNumber(Tokens[Idx], V);
  end;

begin
  Result := False;

  FillChar(TRYYear, SizeOf(TRYYear), 0);
  TRYYear.SourceFileName := FileName;
  SetLength(TRYYear.HourlyRecords, HoursPerYear);
  TRYYear.FilledHours := 0;

  if not FileExists(FileName) then
  begin
    Warn(Format('TRY-Datei "%s" nicht gefunden.', [FileName]));
    Exit;
  end;

  { Jahr aus dem Dateinamen, DWD-Konvention "TRYJJJJ_..." (Zeichen 4-7 =
    Jahreszahl, z. B. "TRY2015_38265002_Jahr.dat" -> 2015). Da für die
    Wärmebilanz nur Kalendertag/-stunde ausgewertet werden, nicht das
    Kalenderjahr selbst, hat ein Fehlschlag hier keinen Einfluss auf das
    Ergebnis - nur auf Schaltjahr-Randfälle (29. Februar). }
  YearFromName := Copy(ExtractFileName(FileName), 4, 4);
  if not TryStrToInt(YearFromName, TRYYear.Year) then
  begin
    Warn(Format('Jahreszahl nicht aus dem Dateinamen "%s" ablesbar (erwartet z. B. "TRY2015_..."), verwende %d.',
      [ExtractFileName(FileName), YearOf(Now)]));
    TRYYear.Year := YearOf(Now);
  end;

  Lines := TStringList.Create;
  Tokens := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      on E: Exception do
      begin
        Warn(Format('TRY-Datei "%s" konnte nicht gelesen werden: %s', [FileName, E.Message]));
        Exit;
      end;
    end;

    StartMarkerFound := False;

    for I := 0 to Lines.Count - 1 do
    begin
      LineNo := I + 1;
      SplitWhitespace(Lines[I], Tokens);

      { Datenzeilen folgen erst nach einer Zeile, deren erstes Token exakt
        '***' ist (Kopfzeilen-Ende-Marker der DWD-TRY-Dateien). }
      if not StartMarkerFound then
      begin
        if (Tokens.Count > 0) and (Tokens[0] = '***') then
          StartMarkerFound := True;
        Continue;
      end;

      if Tokens.Count = 0 then
        Continue;

      if Tokens.Count < MinDataColumns then
      begin
        Warn(Format('Zeile %d: zu wenige Spalten (%d von %d erwartet), übersprungen.',
          [LineNo, Tokens.Count, MinDataColumns]));
        Continue;
      end;

      ParseOK := ReadInt(2, iMonth) and ReadInt(3, iDay) and ReadInt(4, iHour);
      if not ParseOK then
      begin
        Warn(Format('Zeile %d: Monat/Tag/Stunde nicht lesbar, übersprungen.', [LineNo]));
        Continue;
      end;

      { TRY-Stunden sind mit 1..24 beschriftet und bezeichnen die Stunde,
        die zum genannten Zeitpunkt ENDET (Stunde 1 = 00:00-01:00) - daher
        hier -1 für den Beginn der Stunde, wie in der Vorlage. }
      if not TryEncodeDateTime(TRYYear.Year, iMonth, iDay, iHour - 1, 0, 0, 0, iTime) then
      begin
        Warn(Format('Zeile %d: Datum/Uhrzeit (%d.%d., Stunde %d) ungültig, übersprungen.',
          [LineNo, iDay, iMonth, iHour]));
        Continue;
      end;

      HourIndex := HourIndexOfYear(iTime);
      if (HourIndex < 0) or (HourIndex >= HoursPerYear) then
      begin
        Warn(Format('Zeile %d: Stundenindex %d außerhalb des Jahres, übersprungen.', [LineNo, HourIndex]));
        Continue;
      end;

      with TRYYear.HourlyRecords[HourIndex] do
      begin
        Time := iTime;
        Month := iMonth;
        Day := iDay;
        Hour := iHour;
        Filled := True;

        ReadInt(5, Cloudiness);
        ReadInt(6, WindDirection);
        ReadReal(7, WindSpeed);
        ReadReal(8, Temperature);
        ReadReal(9, Pressure);
        ReadReal(10, AbsHumidity);
        ReadReal(11, RelHumidity);
        { Index 12 wird übersprungen (Quell-/Qualitätskennzeichen in der
          Vorlage nicht ausgewertet). }
        ReadReal(13, DirectSunPowerHorizontal);
        ReadReal(14, DiffuseSunPowerHorizontal);
        { Index 15 wird übersprungen (wie 12). }
        ReadReal(16, AtmIrradianceHorizontal);
        ReadReal(17, TerrIrradianceHorizontal);
      end;

      Inc(TRYYear.FilledHours);
    end;

  finally
    Tokens.Free;
    Lines.Free;
  end;

  if not StartMarkerFound then
    Warn(Format('TRY-Datei "%s": kein "***"-Datenmarker gefunden - Dateiformat nicht erkannt, keine Daten importiert.',
      [FileName]));

  if TRYYear.FilledHours = 0 then
  begin
    Warn(Format('TRY-Datei "%s": es konnten keine Stundenwerte gelesen werden.', [FileName]));
    Exit;
  end;

  if TRYYear.FilledHours < HoursPerYear then
    Warn(Format('TRY-Datei "%s": nur %d von %d Stunden des Jahres gefüllt - fehlende Stunden bleiben auf 0.',
      [FileName, TRYYear.FilledHours, HoursPerYear]));

  Result := True;
end;

end.
