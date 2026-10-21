program WaermepumpenSimulation;

{$mode objfpc}{$H+}

// ================================================================
// Waermepumpen-Jahressimulation - Hauptprogramm
//
// Das eigentliche Datenmodell, die Simulation, der HTML-Bericht und
// die Wetter-/Konfigurationsbeschaffung stecken in separaten Units
// (siehe deren Kopfkommentare fuer Details):
//   uWPTypes        - Waermepumpe/Kaskade/Gebaeude (Datenmodell)
//   uWetterdaten    - TRY-Datei / CSV / synthetischer Jahresverlauf
//   uKonfiguration  - Szenarien aus einer INI-Datei laden/schreiben
//   uSimulation     - der eigentliche Stundensimulationskern
//   uBericht        - grafischer HTML-Bericht
//   uTRYImport      - vom Nutzer bereitgestellter DWD-TRY-Parser
//
// Dieses Hauptprogramm macht nur noch: Wetterdaten laden, Szenarien
// aus der Konfigurationsdatei laden (oder eine Beispielkonfiguration
// anlegen, falls keine vorhanden ist), jedes Szenario simulieren und
// die Ergebnisse als CSV/HTML ausgeben.
//
// Kompilieren: alle .pas-Dateien muessen im selben Ordner liegen wie
// diese .lpr - "fpc WaermepumpenSimulation.lpr" findet sie automatisch.
// ================================================================

uses
  SysUtils,
  uWPTypes,
  uWetterdaten,
  uKonfiguration,
  uSimulation,
  uBericht;

const
  WetterDatei = 'wetterdaten.csv';
  WetterBeispielDatei = 'wetterdaten_beispiel.csv';
  KonfigDatei = 'szenarien.ini';
  KonfigBeispielDatei = 'szenarien_beispiel.ini';
  VergleichsDatei = 'szenarienvergleich.csv';
  BerichtDatei = 'bericht.html';

var
  Temps: TDoubleArray;

  Szenarien: TSzenarioKonfigurationArray;
  Ergebnisse: array of TJahresErgebnis;

  I: Integer;
  CSVName: string;
  VergleichFile: TextFile;
  CSVFormat: TFormatSettings;
  DurchschnAktiv: Double;

  TRYDatei: string;
  WetterGeladen, KonfigGeladen: Boolean;
  KonfigQuelle: string;

begin
  CSVFormat := DefaultFormatSettings;
  CSVFormat.DecimalSeparator := ',';

  // --------------------------------------------------------------
  // Wetterdaten laden. Reihenfolge:
  //   1. echte DWD-TRY-Datei ("TRY*" im Programmverzeichnis)
  //   2. einfache CSV-Datei ("wetterdaten.csv")
  //   3. synthetischer Jahresverlauf (inkl. Beispiel-CSV)
  // --------------------------------------------------------------

  WetterGeladen := False;
  TRYDatei := FindTRYFile;

  if TRYDatei <> '' then
  begin
    Writeln('TRY-Datei gefunden: ' + TRYDatei);
    WetterGeladen := LoadWeatherFromTRY(TRYDatei, Temps);
    if WetterGeladen then
      Writeln('Wetterdaten geladen aus: ' + TRYDatei)
    else
      Writeln(
        '"' + TRYDatei + '" konnte nicht als TRY-Datei gelesen ' +
        'werden - versuche Alternativen.');
  end;

  if not WetterGeladen then
    WetterGeladen := LoadWeatherData(WetterDatei, Temps);

  if WetterGeladen and (TRYDatei = '') then
    Writeln('Wetterdaten geladen aus: ' + WetterDatei);

  if not WetterGeladen then
  begin
    GenerateSyntheticWeather(Temps);
    WriteExampleWeatherFile(WetterBeispielDatei, Temps);
    Writeln(
      'Keine TRY-Datei und keine (vollstaendige) "' + WetterDatei +
      '" gefunden - verwende synthetischen Jahresverlauf.');
    Writeln(
      'Ein Beispiel im erwarteten CSV-Format wurde geschrieben ' +
      'nach: ' + WetterBeispielDatei);
    Writeln(
      'Eigene TRY-Daten (Dateiname beginnend mit "TRY", z.B. ' +
      '"TRY2015_38265002_Jahr.dat") werden automatisch erkannt; ' +
      'alternativ eigene Messdaten als "' + WetterDatei +
      '" im CSV-Format.');
  end;
  Writeln;

  // --------------------------------------------------------------
  // Szenarien (Waermepumpen/Kaskaden + Gebaeude) aus einer INI-Datei
  // laden. Reihenfolge, analog zu den Wetterdaten:
  //   1. "szenarien.ini" (eigene Konfiguration)
  //   2. eingebaute Beispiel-Szenarien, geschrieben nach
  //      "szenarien_beispiel.ini" zur Orientierung
  //
  // WICHTIG: alle COP-/Leistungswerte sowie Wirkungsgrad/Brennstoff-
  // preis der "bisherigen Heizung" in der (Beispiel-)Konfiguration
  // sind PLATZHALTER - fuer eine reale Waermepumpe die Punkte aus dem
  // Hersteller-Datenblatt (nach EN 14511) in "szenarien.ini" eintragen.
  // Der Strompreis (StromPreis-Konstante in uSimulation) ist ebenfalls
  // ein Platzhalter.
  // --------------------------------------------------------------

  if FileExists(KonfigDatei) then
  begin
    KonfigQuelle := KonfigDatei;
    Writeln('Konfigurationsdatei gefunden: ' + KonfigDatei);
  end
  else
  begin
    WriteExampleConfiguration(KonfigBeispielDatei);
    KonfigQuelle := KonfigBeispielDatei;
    Writeln(
      'Keine "' + KonfigDatei + '" gefunden - verwende eingebaute ' +
      'Beispiel-Szenarien (geschrieben nach "' + KonfigBeispielDatei +
      '" zur Orientierung). Eigene Waermepumpen/Gebaeude/Szenarien ' +
      'dort eintragen und als "' + KonfigDatei + '" speichern, um sie ' +
      'zu verwenden.');
  end;

  KonfigGeladen := False;
  try
    KonfigGeladen := LoadConfiguration(KonfigQuelle, Szenarien);
  except
    on E: Exception do
    begin
      Writeln('FEHLER beim Einlesen von "' + KonfigQuelle + '": ' +
        E.Message);
      Halt(1);
    end;
  end;

  if not KonfigGeladen then
  begin
    Writeln('FEHLER: "' + KonfigQuelle +
      '" enthaelt keine gueltigen Szenarien ([Szenario:N]-Abschnitte).');
    Halt(1);
  end;

  Writeln(
    Format('%d Szenario(e) aus "%s" geladen.',
      [Length(Szenarien), KonfigQuelle]));
  Writeln;

  SetLength(Ergebnisse, Length(Szenarien));

  try
    Writeln('=============================================');
    Writeln(' Vereinfachte Waermepumpen-Simulation');
    Writeln(' (' + IntToStr(Length(Szenarien)) + ' Szenarien)');
    Writeln('=============================================');
    Writeln;

    for I := 0 to High(Szenarien) do
    begin
      CSVName := Format('ergebnis_szenario_%d.csv', [I + 1]);

      Ergebnisse[I] := RunSimulation(
        Szenarien[I].WP, Szenarien[I].Gebaeude, Temps, CSVName, True);

      // -- Wirtschaftlichkeit (nur aus den Jahressummen, keine
      // stuendliche Granularitaet noetig) -------------------------
      Ergebnisse[I].KostenAlt :=
        (Ergebnisse[I].TotalHeat + Ergebnisse[I].TotalTWW) /
        Szenarien[I].Gebaeude.AltWirkungsgrad *
        Szenarien[I].Gebaeude.AltBrennstoffpreis;

      Ergebnisse[I].KostenNeu :=
        Ergebnisse[I].TotalElectric * StromPreis;

      Ergebnisse[I].Ersparnis :=
        Ergebnisse[I].KostenAlt - Ergebnisse[I].KostenNeu;
    end;

    // ------------------------------------------------------------
    // Zusammenfassung je Szenario (Konsole + CSV)
    // ------------------------------------------------------------

    Writeln('=============================================');
    Writeln(' Jahresergebnisse im Vergleich');
    Writeln('=============================================');
    Writeln;

    AssignFile(VergleichFile, VergleichsDatei);
    Rewrite(VergleichFile);
    try
      Writeln(VergleichFile,
        'Szenario;Heizwaerme_kWh;TWW_kWh;Stromverbrauch_kWh;' +
        'Heizstab_kWh;JAZ;Taktrisiko_Prozent;AbtauRisiko_Stunden;' +
        'KostenAlt_EUR;KostenNeu_EUR;Ersparnis_EUR;AnzahlEinheiten;' +
        'MaxAktiveEinheiten;DurchschnAktiveEinheiten');

      for I := 0 to High(Ergebnisse) do
      begin
        if Ergebnisse[I].ActiveHours > 0 then
          DurchschnAktiv :=
            Ergebnisse[I].SummeAktiveEinheiten / Ergebnisse[I].ActiveHours
        else
          DurchschnAktiv := 0;

        Writeln(Ergebnisse[I].ScenarioName + ':');

        Writeln(
          Format(
            '  Heizwaerme:      %10.1f kWh',
            [Ergebnisse[I].TotalHeat]));
        Writeln(
          Format(
            '  Trinkwarmwasser: %10.1f kWh',
            [Ergebnisse[I].TotalTWW]));
        Writeln(
          Format(
            '  Stromverbrauch:  %10.1f kWh',
            [Ergebnisse[I].TotalElectric]));
        Writeln(
          Format(
            '  davon Heizstab:  %10.1f kWh',
            [Ergebnisse[I].TotalHeater]));
        Writeln(
          Format(
            '  Jahresarbeitszahl:   %5.2f',
            [Ergebnisse[I].JAZ]));
        Writeln(
          Format(
            '  Taktrisiko:          %5.1f %% der Betriebsstunden',
            [Ergebnisse[I].TaktRisikoAnteil]));
        Writeln(
          Format(
            '  Abtau-Risiko:        %5d Stunden/Jahr',
            [Ergebnisse[I].AbtauRisikoStunden]));
        Writeln(
          Format(
            '  Kosten bisherige Heizung (Referenz): %8.0f EUR/Jahr',
            [Ergebnisse[I].KostenAlt]));
        Writeln(
          Format(
            '  Kosten Waermepumpe (Strom):          %8.0f EUR/Jahr',
            [Ergebnisse[I].KostenNeu]));
        Writeln(
          Format(
            '  Ersparnis:                            %8.0f EUR/Jahr',
            [Ergebnisse[I].Ersparnis]));
        if Szenarien[I].WP.AnzahlEinheiten > 1 then
          Writeln(
            Format(
              '  Einheiten (Kaskade):   max. %d von %d aktiv, ' +
              'im Mittel %4.2f bei Betrieb',
              [Ergebnisse[I].MaxAktiveEinheiten,
               Szenarien[I].WP.AnzahlEinheiten, DurchschnAktiv]));
        Writeln;

        Writeln(VergleichFile,
          Format(
            '%s;%.1f;%.1f;%.1f;%.1f;%.2f;%.1f;%d;%.0f;%.0f;%.0f;%d;%d;%.2f',
            [Ergebnisse[I].ScenarioName,
             Ergebnisse[I].TotalHeat,
             Ergebnisse[I].TotalTWW,
             Ergebnisse[I].TotalElectric,
             Ergebnisse[I].TotalHeater,
             Ergebnisse[I].JAZ,
             Ergebnisse[I].TaktRisikoAnteil,
             Ergebnisse[I].AbtauRisikoStunden,
             Ergebnisse[I].KostenAlt,
             Ergebnisse[I].KostenNeu,
             Ergebnisse[I].Ersparnis,
             Szenarien[I].WP.AnzahlEinheiten,
             Ergebnisse[I].MaxAktiveEinheiten,
             DurchschnAktiv],
            CSVFormat));
      end;
    finally
      CloseFile(VergleichFile);
    end;

    Writeln('Szenarienvergleich geschrieben nach: ' +
      VergleichsDatei);

    GenerateHTMLReport(Ergebnisse, Szenarien, BerichtDatei);
    Writeln('Grafischer HTML-Bericht geschrieben nach: ' +
      BerichtDatei);

    Writeln;
    Writeln('Simulation beendet.');

  finally
    for I := 0 to High(Szenarien) do
    begin
      Szenarien[I].WP.Free;
      Szenarien[I].Gebaeude.Free;
    end;
  end;
end.
