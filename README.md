# reminders-mcp

Lokale MCP-server voor Apple Herinneringen op macOS, **standaard alleen-lezen**. Werkt via Apple's EventKit
met de herinneringen die macOS zelf met iCloud synchroniseert. Schrijven (aanmaken, wijzigen, verwijderen)
zet je per onderdeel zelf aan. Geen iCloud-login, geen wachtwoord, geen
scraping, geen netwerkverkeer: de server praat alleen via stdio met de agent die hem start.

## Installeren

Vereist: macOS 14 of nieuwer en de Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install
```

Dit bouwt één binair bestand en zet het in `~/.local/bin/reminders-mcp`. Geef daarna eenmalig toestemming:

```bash
~/.local/bin/reminders-mcp --check
```

macOS toont het venster "reminders-mcp wil toegang tot je herinneringen". Kies **Sta toe**. De uitvoer
toont daarna `"status": "full_access"`.

## Koppelen aan Codex

```bash
codex mcp add apple-reminders -- ~/.local/bin/reminders-mcp
```

Of handmatig in `~/.codex/config.toml`:

```toml
[mcp_servers.apple-reminders]
command = "/Users/JOUWNAAM/.local/bin/reminders-mcp"
```

Codex start de server zelf wanneer een sessie of automatisering begint; er hoeft niets op de achtergrond
te draaien. Voorbeeldopdracht voor de planning van 7:00:

> Roep `reminders_daily_overview` aan en maak mijn dagplanning. Houd `due_on_date` (vandaag) en
> `overdue` (achterstallig) gescheiden.

Andere MCP-clients werken hetzelfde: commando `~/.local/bin/reminders-mcp`, transport stdio, geen argumenten.

## Tools

| Tool | Doel |
| --- | --- |
| `reminders_daily_overview` | Dagoverzicht voor vandaag of een andere `date` (YYYY-MM-DD, `vandaag`, `morgen`). Aparte groepen `due_on_date` en `overdue`; optioneel `undated`. |
| `reminders_list_open` | Volledige lijst van alle open herinneringen, optioneel gefilterd op lijst en vervaldatumperiode. |
| `reminders_lists` | Alle lijsten met account en aantal open herinneringen. |
| `reminders_access_status` | Toestemmingsstatus, tijdzone en de datum die als "vandaag" geldt. Opent geen venster. |

Per herinnering: `title`, `list`, `account`, `has_due_date`, `due` (`date`, `time`, `all_day`, `iso`),
`is_overdue`, `days_overdue`, `notes`, `priority`, `recurrence`, `alarms`, `created_at`, `modified_at`
en `subtasks`. Elk antwoord bevat `field_availability` met wat EventKit wel en niet levert.

### Schrijftools (standaard uit)

Zonder instelling biedt de server alleen de vier leestools aan. Met de omgevingsvariabele
`REMINDERS_MCP_WRITE` zet je schrijven aan; combineer met komma's of gebruik `all`.

| Waarde | Tools | Wat het doet |
| --- | --- | --- |
| `create` | `reminders_create`, `reminders_create_list` | Herinnering aanmaken met titel, lijst, vervaldatum/-tijd, notitie, prioriteit en herhaling; lege lijst aanmaken. |
| `update` | `reminders_update` | Velden wijzigen, naar een andere lijst verplaatsen, afvinken of weer openzetten. |
| `delete` | `reminders_delete` | Definitief verwijderen; vereist de exacte titel in `confirm_title`. |

Voor Codex, bijvoorbeeld alleen aanmaken en wijzigen:

```bash
codex mcp remove apple-reminders
```

```bash
codex mcp add apple-reminders --env REMINDERS_MCP_WRITE=create,update -- ~/.local/bin/reminders-mcp
```

Een vervaldatum met tijd krijgt automatisch een melding op dat moment. Lijsten hernoemen of verwijderen
kan niet. Subtaken, tags en de vlag kunnen niet worden gezet (EventKit biedt dat niet).

### Hoe "vandaag" wordt bepaald

- **Vandaag** = de kalenderdag van 00:00 tot 24:00 in de systeemtijdzone van de Mac, bij elke aanroep
  opnieuw uitgelezen. Elk antwoord vermeldt `time_zone`, `generated_at` en de gebruikte definitie.
- **`due_on_date`** = open herinneringen met vervaldatum op die dag. Een tijd met eigen tijdzone wordt
  eerst naar lokale tijd omgerekend; "hele dag" telt op de kalenderdatum. Is het tijdstip vandaag al
  voorbij, dan blijft de herinnering hier staan met `is_overdue: true`.
- **`overdue`** = open herinneringen met vervaldatum vóór 00:00 van vandaag (bij een datum in het
  verleden: vóór die dag).
- Geen vervaldatum → `has_due_date: false`, `due: null` en `due_note`. In het dagoverzicht alleen
  meegegeven met `include_undated: true`; in `reminders_list_open` standaard.

## Toegang en privacy

- **Toestemming:** alleen Herinneringen. EventKit kent voor Herinneringen geen aparte leestoestemming;
  "volledige toegang" is de kleinste toestemming waarmee lezen kan. Schrijftools bestaan alleen als
  `REMINDERS_MCP_WRITE` ze aanzet; anders worden ze niet aangeboden en geweigerd.
- **Geweigerd of ontbrekend:** elke tool geeft dan `reminders_access_missing` met uitleg en stappen
  (Systeeminstellingen > Privacy en beveiliging > Herinneringen > `reminders-mcp` aanzetten). Opnieuw
  laten vragen: `tccutil reset Reminders` en daarna `reminders-mcp --check`.
- **Geen kopieën:** herinneringen bestaan alleen in het geheugen tijdens één aanroep. Geen cache, geen bestanden.
- **Logs:** alleen naar stderr, alleen toolnaam, aantallen en doorlooptijd. Nooit titels, notities of lijstnamen.
- Wat de agent met het antwoord doet (bijv. in zijn eigen sessielog bewaren) valt buiten deze server.

## Beperkingen (eerlijk)

- **Subtaken:** EventKit levert geen ouder/kind-relatie. Subtaken staan wel in de resultaten, maar als
  losse herinneringen; `subtasks` is dan `null`. Optioneel, standaard uit: met
  `REMINDERS_MCP_SUBTASKS=sqlite` leest de server alleen de id-paren (kind → hoofdtaak) uit de lokale
  Herinneringen-database. Dat vereist **Volledige schijftoegang** voor `reminders-mcp`, leunt op een
  ongedocumenteerd schema dat per macOS-versie kan wijzigen, en is op deze Mac **niet getest** (geen
  schijftoegang tijdens het bouwen). Herkent de server het schema niet, dan meldt hij dat in plaats van te gokken.
- **Niet beschikbaar via EventKit:** tags, vlag, secties/kolommen, slimme lijsten, lijstgroepen,
  bijlagen, toewijzing in gedeelde lijsten, vroege herinneringen; het URL-veld meestal niet.
- **Herhaling:** je ziet de regel en de eerstvolgende open keer, niet toekomstige keren. Wat er gebeurt
  als je een herhalende herinnering via `reminders_update` afvinkt (volgende keer wel of niet
  aangemaakt) is **niet getest**.
- **Id's:** het `id` van een herinnering kan na een iCloud-synchronisatie wijzigen. Haal een
  herinnering opnieuw op vlak voordat je hem wijzigt of verwijdert.
- **`reminders_create_list`** is gebouwd maar niet getest.
- **Actualiteit:** de server leest wat macOS lokaal heeft gesynchroniseerd. Sliep de Mac of was hij
  offline, dan kan het overzicht van 7:00 wijzigingen van je iPhone missen. De Mac moet aan staan en
  ingelogd zijn; de server kan zelf geen iCloud-synchronisatie afdwingen.
- **Toestemming hangt aan het binaire bestand:** het is ad-hoc ondertekend. Na opnieuw bouwen of
  verplaatsen kan macOS opnieuw om toestemming vragen; voer dan `reminders-mcp --check` uit.
- **Eigen verantwoordelijke:** normaal koppelt macOS de toestemming aan de startende app (Codex,
  Terminal). Vanuit zo'n app verscheen er tijdens het testen geen toestemmingsvenster. Daarom herstart
  de server zichzelf één keer via `responsibility_spawnattrs_setdisclaim`, zodat de toestemming bij
  `reminders-mcp` zelf hoort. Dat is een niet-publieke macOS-functie (ook gebruikt door o.a. Chromium);
  valt ze weg, dan werkt de server verder onder de toestemming van de startende app. Uitzetten:
  `REMINDERS_MCP_NO_DISCLAIM=1`.

## Handmatig testen

```bash
~/.local/bin/reminders-mcp --overview
```

Print het dagoverzicht van vandaag als JSON (met inhoud, dus alleen in je eigen terminal gebruiken).

## Licentie

MIT, zie [LICENSE](LICENSE).
