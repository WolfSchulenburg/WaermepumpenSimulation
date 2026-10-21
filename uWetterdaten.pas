unit uWetterdaten;

{$mode objfpc}{$H+}

// ================================================================
// Wetterdaten-Beschaffung fuer die Jahressimulation. Reihenfolge der
// Quellen (siehe Hauptprogramm):
//   1. echte DWD-TRY-Datei ("TRY*" im Programmverzeichnis, Unit
//      uTRYImport)
//   2. einfache CSV-Datei ("wetterdaten.csv")
//   3. synthetischer Jahresverlauf (inkl. geschriebener Beispiel-CSV)
// ================================================================

interface

uses
  SysUtils, Classes, uWPTypes, uTRYImport;

// Erzeugt den synthetischen Jahresverlauf der Urspungsversion
// (Sinus-foermiger Jahres- und Tagesgang um 10 °C Mitteltemperatur).
procedure GenerateSyntheticWeather(var Temps: TDoubleArray);

// Versucht, eine Zahl unabhaengig vom Dezimaltrennzeichen
// (Punkt oder Komma) zu parsen.
function TryParseTemperature(S: string; out Value: Double): Boolean;

// Liest Wetterdaten aus einer CSV-Datei.
//
// Erwartetes Format: eine Zeile je Stunde, entweder
//   "<Temperatur>"                oder
//   "<Stunde>;<Temperatur>"       oder
//   "<Datum/Stunde>;<Temperatur>"
// Dezimaltrennzeichen Punkt oder Komma, Spalten durch Semikolon,
// Komma oder Tab getrennt. Eine evtl. vorhandene Kopfzeile (nicht
// numerisch) wird uebersprungen. Es werden maximal 8760 Werte
// gelesen; enthaelt die Datei weniger Zeilen, wird das Ergebnis
// als ungueltig zurueckgegeben.
function LoadWeatherData(const FileName: string;
  var Temps: TDoubleArray): Boolean;

// Schreibt einen Beispiel-Wetterdatensatz (synthetischer Verlauf),
// damit das erwartete CSV-Format sofort ersichtlich ist und eigene
// Messdaten (z.B. vom DWD) leicht im selben Format eingesetzt
// werden koennen.
procedure WriteExampleWeatherFile(const FileName: string;
  const Temps: TDoubleArray);

// ------------------------------------------------------------
// Echte DWD-TRY-Datei (Testreferenzjahr)
//
// Sucht im Programmverzeichnis nach einer Datei, deren Name mit
// "TRY" beginnt (DWD-Konvention, z.B. "TRY2015_38265002_Jahr.dat")
// und liest daraus die Stundentemperaturen ueber die Unit
// uTRYImport. Deren Spaltenzuordnung ist dort dokumentiert und wird
// hier nicht angetastet.
// ------------------------------------------------------------

function FindTRYFile: string;

function LoadWeatherFromTRY(const FileName: string;
  var Temps: TDoubleArray): Boolean;

implementation

uses
  Math;

procedure GenerateSyntheticWeather(var Temps: TDoubleArray);
var
  Hour: Integer;
  Day: Double;
  SeasonalVariation, DailyVariation: Double;
begin
  SetLength(Temps, 8760);

  for Hour := 0 to 8759 do
  begin
    Day := Hour / 24.0;

    SeasonalVariation :=
      -10.0 * Cos(2.0 * Pi * (Day - 15.0) / 365.0);

    DailyVariation :=
      3.0 * Sin(2.0 * Pi * (Hour mod 24) / 24.0);

    Temps[Hour] := 10.0 + SeasonalVariation + DailyVariation;
  end;
end;

function TryParseTemperature(S: string; out Value: Double): Boolean;
var
  FS: TFormatSettings;
begin
  S := Trim(S);
  FS := DefaultFormatSettings;

  FS.DecimalSeparator := '.';
  if TryStrToFloat(S, Value, FS) then
    Exit(True);

  FS.DecimalSeparator := ',';
  if TryStrToFloat(S, Value, FS) then
    Exit(True);

  Result := False;
end;

function LoadWeatherData(const FileName: string;
  var Temps: TDoubleArray): Boolean;
var
  Zeilen: TStringList;
  Teile: TStringList;
  I: Integer;
  Wert: Double;
  Anzahl: Integer;
begin
  Result := False;

  if not FileExists(FileName) then
    Exit;

  Zeilen := TStringList.Create;
  Teile := TStringList.Create;
  try
    Zeilen.LoadFromFile(FileName);

    SetLength(Temps, 8760);
    Anzahl := 0;

    for I := 0 to Zeilen.Count - 1 do
    begin
      if Trim(Zeilen[I]) = '' then
        Continue;

      Teile.Clear;
      Teile.Delimiter := ';';
      Teile.StrictDelimiter := True;
      Teile.DelimitedText :=
        StringReplace(
          StringReplace(Zeilen[I], #9, ';', [rfReplaceAll]),
          ',', ';', [rfReplaceAll]);

      // Bei "Zahl,Nachkommastelle" ohne weitere Spalte kann obiges
      // Ersetzen das Dezimalkomma zerstoeren -- daher zuerst
      // versuchen, die ganze Zeile direkt als eine Zahl zu lesen.
      if TryParseTemperature(Zeilen[I], Wert) then
      begin
        if Anzahl < 8760 then
        begin
          Temps[Anzahl] := Wert;
          Inc(Anzahl);
        end;
        Continue;
      end;

      if (Teile.Count > 0) and
         TryParseTemperature(Teile[Teile.Count - 1], Wert) then
      begin
        if Anzahl < 8760 then
        begin
          Temps[Anzahl] := Wert;
          Inc(Anzahl);
        end;
      end;
      // Zeilen, die sich nicht als Zahl interpretieren lassen
      // (z.B. eine Kopfzeile), werden stillschweigend uebersprungen.
    end;

    if Anzahl >= 8760 then
    begin
      SetLength(Temps, 8760);
      Result := True;
    end
    else
      Writeln(
        Format(
          'Warnung: "%s" enthaelt nur %d gueltige Werte (8760 ' +
          'benoetigt) - verwende stattdessen den synthetischen ' +
          'Jahresverlauf.',
          [FileName, Anzahl]));
  finally
    Teile.Free;
    Zeilen.Free;
  end;
end;

procedure WriteExampleWeatherFile(const FileName: string;
  const Temps: TDoubleArray);
var
  F: TextFile;
  I: Integer;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := ',';

  AssignFile(F, FileName);
  Rewrite(F);
  try
    Writeln(F, 'Stunde;Aussentemperatur_C');
    for I := 0 to High(Temps) do
      Writeln(F, Format('%d;%.2f', [I, Temps[I]], FS));
  finally
    CloseFile(F);
  end;
end;

function FindTRYFile: string;
var
  SearchRec: TSearchRec;
begin
  Result := '';

  if FindFirst('TRY*', faAnyFile, SearchRec) = 0 then
  begin
    repeat
      if (SearchRec.Attr and faDirectory) = 0 then
      begin
        Result := SearchRec.Name;
        Break;
      end;
    until FindNext(SearchRec) <> 0;
    FindClose(SearchRec);
  end;
end;

function LoadWeatherFromTRY(const FileName: string;
  var Temps: TDoubleArray): Boolean;
var
  TRYYear: TTRYYear;
  Warnings: TStringList;
  I: Integer;
begin
  Result := False;

  Warnings := TStringList.Create;
  try
    Result := LoadTRYYear(FileName, TRYYear, Warnings);

    for I := 0 to Warnings.Count - 1 do
      Writeln('  ' + Warnings[I]);

    if not Result then
      Exit;

    SetLength(Temps, HoursPerYear);
    for I := 0 to HoursPerYear - 1 do
      Temps[I] := TRYYear.HourlyRecords[I].Temperature;

    Writeln(
      Format(
        '  Jahresmitteltemperatur laut TRY-Datei: %.1f C ' +
        '(%d von %d Stunden aus der Datei, Rest = 0)',
        [AverageTemperature(TRYYear), TRYYear.FilledHours,
         HoursPerYear]));
  finally
    Warnings.Free;
  end;
end;

end.
