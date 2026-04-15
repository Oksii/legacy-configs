# stats.lua

ETLegacy server-side Lua stats module. Collects per-round weapon stats, objective tracking,
movement/stance metrics, and a rich in-round event timeline (`gamelog`). Submits a single JSON
payload to a configurable API endpoint at the end of every round.

---

## Output JSON structure

```json
{
  "round_info":   { ... },
  "player_stats": { "<guid>": { ... } },
  "metadata":     { ... },
  "gamelog":      [ { ... } ]
}
```

### `round_info`

Round outcome and timing data.

> **Deprecation notice:** The fields `servername`, `config`, `matchID`, `stats_version`,
> `mod_version`, `et_version`, `server_ip`, and `server_port` are duplicated here for
> backwards compatibility but have moved to [`metadata`](#metadata). 
> read those fields from `metadata` and treat the copies in `round_info` as legacy.

| Field | Type | Description |
|-------|------|-------------|
| `servername` | string | *(legacy — prefer `metadata.servername`)* `sv_hostname` |
| `config` | string | *(legacy — prefer `metadata.config`)* `g_customConfig` |
| `matchID` | string | *(legacy — prefer `metadata.matchID`)* Match ID from API, or unix timestamp fallback |
| `stats_version` | string | *(legacy — prefer `metadata.stats_version`)* stats.lua module version (e.g. `"2.0.0"`) |
| `mod_version` | string | *(legacy — prefer `metadata.mod_version`)* ETLegacy mod version (e.g. `"v2.83.2-594-g5cdc1c9"`) |
| `et_version` | string | *(legacy — prefer `metadata.et_version`)* ET engine version (e.g. `"ET 2.60b linux-x86_64"`) |
| `server_ip` | string | *(legacy — prefer `metadata.server_ip`)* Resolved server IP |
| `server_port` | string | *(legacy — prefer `metadata.server_port`)* Server port |
| `mapname` | string | Current map |
| `round` | number | 1 or 2 |
| `defenderteam` | number | Defending team (1=Axis, 2=Allies) |
| `winnerteam` | number | Winning team |
| `timelimit` | string | Timelimit in `M:SS` format |
| `nextTimeLimit` | string | Next-round timelimit |
| `round_start` | number | Level time (ms) when round started |
| `round_end` | number | Level time (ms) when round ended |
| `round_start_unix` | number | Unix timestamp when round started |
| `round_end_unix` | number | Unix timestamp when round ended |

### `player_stats`

Keyed by GUID. Each entry includes:

| Field | Type | Description |
|-------|------|-------------|
| `guid` | string | First 8 chars of GUID |
| `name` | string | Player name at round end |
| `rounds` | string | Rounds played |
| `team` | string | Final team |
| `weaponStats` | array | Raw weapon stat tokens (hits, atts, kills, deaths, headshots per weapon) |
| `distance_travelled_meters` | number | Total distance (metres) |
| `distance_travelled_spawn` | number | Distance travelled in first 3s after each spawn (total) |
| `distance_travelled_spawn_avg` | number | Per-spawn average |
| `spawn_count` | number | Number of spawns detected |
| `player_speed` | object | `ups_avg`, `ups_peak`, `kph_avg`, `kph_peak`, `mph_avg`, `mph_peak` |
| `stance_stats_seconds` | object | Seconds spent in each stance (see below) |
| `obj_planted` | object | `{ leveltime: { objective, timestamp_unix } }` |
| `obj_defused` | object | Same |
| `obj_destroyed` | object | Same |
| `obj_repaired` | object | Same |
| `obj_taken` | object | Same |
| `obj_secured` | object | Same |
| `obj_returned` | object | Same |
| `obj_carrierkilled` | object | `{ leveltime: { victim, weapon, objective, timestamp_unix } }` |
| `obj_flagcaptured` | object | `{ leveltime: { objective, timestamp_unix } }` |
| `obj_misc` | object | Same |
| `obj_escort` | object | Same |
| `shoves_given` | object | `{ leveltime: { objective (target GUID), timestamp_unix } }` |
| `shoves_received` | object | Same |

**`stance_stats_seconds` fields:**

| Field | Description |
|-------|-------------|
| `in_prone` | Seconds spent prone |
| `in_crouch` | Seconds crouching (excludes prone / mounted) |
| `in_mg` | Seconds on MG42 / mounted tank / mobile MG |
| `in_lean` | Seconds leaning (excludes prone / mounted) |
| `in_objcarrier` | Seconds carrying a flag/objective |
| `in_vehiclescort` | Seconds connected to a vehicle (tank escort) |
| `in_disguise` | Seconds disguised (covert ops) |
| `in_sprint` | Seconds sprinting (stamina depleting) |
| `in_turtle` | Seconds with zero stamina / full recovery (standing still) |
| `is_downed` | Seconds in downed (revivable) state |

### `metadata`

Present on every submission. Contains server identity and runtime context — versions, active
gather feature flags, and (when `AUTO_SCORES` is on) the current score state.

| Field | Type | Description |
|-------|------|-------------|
| `servername` | string | `sv_hostname` |
| `config` | string | `g_customConfig` |
| `stats_version` | string | stats.lua module version |
| `mod_version` | string | ETLegacy mod version |
| `et_version` | string | ET engine version |
| `server_ip` | string | Resolved server IP |
| `server_port` | string | Server port |
| `matchID` | string | Match ID |
| `features` | object \| null | Active gather feature flags (omitted if none) |
| `scores` | object \| null | Current score state (omitted when `AUTO_SCORES` is off or no rounds processed yet — see below) |

**`features` fields** (all boolean):

| Field | Description |
|-------|-------------|
| `auto_rename` | Team name enforcement active |
| `auto_sort` | Auto-sort to roster team active |
| `auto_start` | Scheduled-start countdown active |
| `auto_map` | Auto map rotation active |
| `auto_config` | Auto server config active |
| `auto_scores` | Score tracking active |

**`scores` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `alpha` | number | Alpha team cumulative score |
| `beta` | number | Beta team cumulative score |
| `alpha_teamname` | string \| null | Alpha team display name (gather: from route; ng: tag-detected) |
| `beta_teamname` | string \| null | Beta team display name |
| `completed_maps` | number | Maps fully played (both rounds done) |
| `match_finished` | boolean | True if match is over |
| `match_winner` | `"alpha"` \| `"beta"` \| `"draw"` \| null | Winner, or null if still in progress |
| `round` | object | Summary of the round just processed (see below) |

**`scores.round` fields:**

| Field | Type | Description |
|-------|------|-------------|
| `map_num` | number | Map number (1–3) |
| `round_num` | number | Round number within the map (1 or 2) |
| `winner` | `"alpha"` \| `"beta"` | Which gather team won this round |
| `winner_et` | number | ET team that won (1=axis, 2=allies) |
| `alpha_side` | number | ET team alpha was playing as this round |
| `fullhold` | boolean | True if `timelimit == nextTimeLimit` (defending team held full time) |

---

### `gamelog`

Ordered array of all events that occurred during the round. Every entry has:

| Field | Type | Description |
|-------|------|-------------|
| `match_id` | string | Match ID (injected at save time) |
| `round_id` | number | Round number (injected at save time) |
| `unixtime` | number | Unix timestamp in **milliseconds** when event was recorded |
| `leveltime` | number | Server level time (ms) when event was recorded |
| `group` | string | `"player"` or `"server"` |
| `label` | string | Event type (see below) |
| ...fields | — | Event-specific fields |

#### Event types

**`spawn`** — player spawned (not a revive)

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `team` | Team number |
| `class` | Class name |
| `weapons` | Array of notable weapon names at spawn (absent for medic/fieldop or when no notable weapon active) |

**`kill`** — player killed an enemy

| Field | Description |
|-------|-------------|
| `killer` | GUID |
| `victim` | GUID |
| `weapon` | meansOfDeath constant |
| `killer_health` | Killer health at moment of kill |
| `killer_class` | `soldier`, `medic`, `engineer`, `fieldop`, `covertops` |
| `killer_pos` | `"x y z"` |
| `killer_stance` | Stance snapshot (see below) |
| `victim_class` | Class |
| `victim_pos` | `"x y z"` |
| `victim_stance` | Stance snapshot |
| `allies_alive` | Allies alive at moment of kill |
| `axis_alive` | Axis alive at moment of kill |
| `killer_reinf` | Seconds until killer's team next reinforce wave |
| `victim_reinf` | Seconds until victim's team next reinforce wave |

**`suicide`** — self-kill or world-kill

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `weapon` | meansOfDeath |
| `victim_class` | Class |
| `victim_pos` | `"x y z"` |
| `victim_stance` | Stance snapshot |

**`teamkill`** — killed a teammate

| Field | Description |
|-------|-------------|
| `killer` | GUID |
| `victim` | GUID |
| `weapon` | meansOfDeath |
| `killer_class` | Class |
| `killer_stance` | Stance snapshot |
| `victim_class` | Class |
| `victim_health` | Victim health at time of kill |
| `victim_stance` | Stance snapshot |

**`damage`** — every damage event (high volume)

| Field | Description |
|-------|-------------|
| `killer` | GUID of attacker (or `"WORLD"`) |
| `victim` | GUID |
| `damage` | Damage amount |
| `damage_flags` | Damage flags bitmask |
| `weapon` | meansOfDeath |
| `hit_region` | `HR_HEAD`, `HR_ARMS`, `HR_BODY`, `HR_LEGS`, `HR_NONE` — see note below |
| `killer_health` / `killer_class` / `killer_pos` / `killer_stance` | Attacker context |
| `victim_health` / `victim_class` / `victim_pos` / `victim_stance` | Victim context |

> **`HR_NONE` note** — `HR_NONE` does not indicate a miss; it means the engine hit-region delta could not be
> determined for this damage event. Based on match data (~27% of all damage events are `HR_NONE`), the
> causes break down as follows:
>
> | Cause | ~% | Explanation |
> |---|---|---|
> | Dead body hit | 66% | Target was already dead; engine skips `G_LogRegionHit` for dead targets so the attacker's `hitRegions` counter never increments |
> | Splash / explosive | 31% | Radius damage has no body-part detection (`DAMAGE_RADIUS` flag set); `G_LogRegionHit` is never called |
> | Cache init | 1.5% | First damage event from an attacker each round; the Lua-side delta cache is seeded on the first call and always returns `HR_NONE` |
> | No victim | 1.3% | Damage to a non-tracked entity (spectator slot, world object, etc.) |
>
> `hit_region` is derived by delta-comparing the attacker's `pers.playerStats.hitRegions[0..3]` counters
> (HEAD/ARMS/BODY/LEGS) between consecutive `et_Damage` callbacks.  The engine only increments these
> counters for direct hits on living players, which is why the above scenarios all produce `HR_NONE`.
> `HR_NONE` is a Lua-level sentinel (`-1`) — it does not exist in the engine's `hitRegion_t` enum.

**`revive`** — medic revived a downed player

| Field | Description |
|-------|-------------|
| `player` | Medic GUID (from `et_Revive` engine callback) |
| `victim` | Revived player GUID |

**`class_change`** — player switched class

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `class` | New class name |

**`message`** — chat / vsay

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `command` | `say`, `say_team`, `say_teamNL`, `say_buddy`, `say_buddyNL`, `vsay`, `vsay_team`, `vsay_buddy` |
| `message` | Message text (vsay: sound key; say: full text) |
| `vsay_text` | Custom text for vsay commands with extra args (optional) |

**Objective events** — `obj_planted`, `obj_defused`, `obj_destroyed`, `obj_repaired`,
`obj_taken`, `obj_secured`, `obj_returned`, `obj_carrierkilled`

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `objective` | Objective name from config |

**`obj_flag_captured`**

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `flag` | Flag name (`allies_flag`, `axis_flag`, or config key) |

**`pickup`** — console-log pickup/use event

`Item:` is the canonical pickup/use signal. When `Ammo_Pack:` or `Health_Pack:` appears on the same log frame, it attributes that same pickup to another player's pack instead of creating a second event.

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `item` | Raw item token from the log, e.g. `item_health`, `weapon_magicammo`, `weapon_mp40`, `weapon_thompson` |
| `owner` | GUID of the player whose health/ammo pack was used (optional; absent for self-use and generic weapon pickups) |
| `pos` | `"x y z"` player origin at the time the line was processed |
| `stance` | Stance snapshot for the acting player |
| `owner_pos` | `"x y z"` owner origin at the time the line was processed (optional) |
| `owner_stance` | Owner stance snapshot (optional) |

**`shove`**

| Field | Description |
|-------|-------------|
| `player` | Shover GUID |
| `victim` | Shoved player GUID |

**`weapon_fire`** — every weapon shot; only present when `COLLECT_WEAPON_FIRE = true`

| Field | Description |
|-------|-------------|
| `player` | GUID |
| `weapon` | `et.WP_*` weapon constant |
| `pos` | `"x y z"` player origin at time of shot |
| `pitch` | View pitch (degrees, 1 decimal) |
| `yaw` | View yaw (degrees, 1 decimal) |
| `stance` | Stance snapshot (see below) |

**Server events** (`group: "server"`)

| Label | Description |
|-------|-------------|
| `round_start` | Emitted when gamestate transitions to GS_PLAYING |
| `round_end` | Emitted when gamestate transitions to GS_INTERMISSION |

**Stance snapshot** (embedded in kill / teamkill / damage / pickup / weapon_fire events):

```json
{
  "is_prone":        false,
  "is_crouch":       false,
  "is_mounted":      false,
  "is_leaning":      false,
  "is_carrying_obj": false,
  "is_disguised":    false,
  "is_downed":       false,
  "is_sprint":       false
}
```

---

## TypeScript types

```typescript
// ─── Primitives ────────────────────────────────────────────────────────────

type Guid        = string;  // 32-char uppercase hex player GUID
type LevelTime   = number;  // server milliseconds since map load
type UnixTime    = number;  // Unix timestamp (seconds)
type Position    = string;  // "x y z" integer coords

type PlayerClass = "soldier" | "medic" | "engineer" | "fieldop" | "covertops" | "unknown";
type TeamNumber  = 0 | 1 | 2 | 3;  // 0=free 1=axis 2=allies 3=spectator
type HitRegion   = "HR_HEAD" | "HR_ARMS" | "HR_BODY" | "HR_LEGS" | "HR_NONE";
type ChatCommand = "say" | "say_team" | "say_teamNL" | "say_buddy" | "say_buddyNL"
                 | "vsay" | "vsay_team" | "vsay_buddy";
type SpawnWeapon = "panzerfaust" | "flamethrower" | "mobile_mg42" | "mobile_browning"
                 | "bazooka" | "carbine" | "kar98"
                 | "sten" | "mp34" | "fg42" | "garand_sniper" | "k43_sniper";

// ─── round_info ────────────────────────────────────────────────────────────
// Fields marked @deprecated are duplicated in Metadata; prefer reading them there.

interface RoundInfo {
  /** @deprecated prefer metadata.servername */  servername:    string;
  /** @deprecated prefer metadata.config */      config:        string;
  /** @deprecated prefer metadata.matchID */     matchID:       string;
  /** @deprecated prefer metadata.stats_version */ stats_version: string;
  /** @deprecated prefer metadata.mod_version */ mod_version:   string;
  /** @deprecated prefer metadata.et_version */  et_version:    string;
  /** @deprecated prefer metadata.server_ip */   server_ip:     string;
  /** @deprecated prefer metadata.server_port */ server_port:   string;
  mapname:          string;
  round:            1 | 2;
  defenderteam:     TeamNumber;
  winnerteam:       TeamNumber;
  timelimit:        string;   // "M:SS"
  nextTimeLimit:    string;
  round_start:      LevelTime;
  round_end:        LevelTime;
  round_start_unix: UnixTime;
  round_end_unix:   UnixTime;
}

// ─── player_stats ──────────────────────────────────────────────────────────

interface PlayerSpeed {
  ups_avg:  number;
  ups_peak: number;
  kph_avg:  number;
  kph_peak: number;
  mph_avg:  number;
  mph_peak: number;
}

interface StanceStatsSeconds {
  in_prone:        number;
  in_crouch:       number;
  in_mg:           number;
  in_lean:         number;
  in_objcarrier:   number;
  in_vehiclescort: number;
  in_disguise:     number;
  in_sprint:       number;
  in_turtle:       number;
  is_downed:       number;
}

/** Standard objective stat entry — keyed by leveltime (as string). */
interface ObjStatEntry {
  objective:      string;
  timestamp_unix: UnixTime;
}

/** Carrier-kill entry — keyed by leveltime (as string). */
interface ObjCarrierKilledEntry {
  victim:         Guid;
  weapon:         number;
  objective:      string;
  timestamp_unix: UnixTime;
}

type ObjStatMap          = Record<string, ObjStatEntry>;
type ObjCarrierKilledMap = Record<string, ObjCarrierKilledEntry>;

interface PlayerStat {
  guid:        string;   // first 8 chars of GUID
  name:        string;
  rounds:      string;
  team:        string;
  weaponStats: string[]; // raw space-separated token per weapon slot

  // COLLECT_MOVEMENT_STATS
  distance_travelled_meters?:    number;
  distance_travelled_spawn?:     number;
  distance_travelled_spawn_avg?: number;
  spawn_count?:                  number;
  player_speed?:                 PlayerSpeed;

  // COLLECT_STANCE_STATS
  stance_stats_seconds?: StanceStatsSeconds;

  // COLLECT_OBJ_STATS
  obj_planted?:       ObjStatMap;
  obj_defused?:       ObjStatMap;
  obj_destroyed?:     ObjStatMap;
  obj_repaired?:      ObjStatMap;
  obj_taken?:         ObjStatMap;
  obj_secured?:       ObjStatMap;
  obj_returned?:      ObjStatMap;
  obj_carrierkilled?: ObjCarrierKilledMap;
  obj_flagcaptured?:  ObjStatMap;
  obj_misc?:          ObjStatMap;
  obj_escort?:        ObjStatMap;

  // COLLECT_SHOVE_STATS — objective field contains the other player's GUID
  shoves_given?:    ObjStatMap;
  shoves_received?: ObjStatMap;
}

type PlayerStats = Record<Guid, PlayerStat>;

// ─── gamelog ───────────────────────────────────────────────────────────────

interface GamelogEventBase {
  match_id:  string;
  round_id:  number;
  unixtime:  number;  // milliseconds since Unix epoch
  leveltime: LevelTime;
  group:     "player" | "server";
  label:     string;
}

interface StanceSnapshot {
  is_prone:        boolean;
  is_crouch:       boolean;
  is_mounted:      boolean;
  is_leaning:      boolean;
  is_carrying_obj: boolean;
  is_disguised:    boolean;
  is_downed:       boolean;
  is_sprint:       boolean;
}

interface SpawnEvent extends GamelogEventBase {
  group:    "player";
  label:    "spawn";
  player:   Guid;
  team:     TeamNumber;
  class:    PlayerClass;
  weapons?: SpawnWeapon[];
}

interface KillEvent extends GamelogEventBase {
  group:         "player";
  label:         "kill";
  killer:        Guid;
  victim:        Guid;
  weapon:        number;
  killer_health: number;
  killer_class:  PlayerClass;
  killer_pos:    Position;
  killer_stance: StanceSnapshot;
  victim_class:  PlayerClass;
  victim_pos:    Position;
  victim_stance: StanceSnapshot;
  allies_alive:  number;
  axis_alive:    number;
  killer_reinf:  number;
  victim_reinf:  number;
}

interface SuicideEvent extends GamelogEventBase {
  group:         "player";
  label:         "suicide";
  player:        Guid;
  weapon:        number;
  victim_class:  PlayerClass;
  victim_pos:    Position;
  victim_stance: StanceSnapshot;
}

interface TeamkillEvent extends GamelogEventBase {
  group:         "player";
  label:         "teamkill";
  killer:        Guid;
  victim:        Guid;
  weapon:        number;
  killer_class:  PlayerClass;
  killer_stance: StanceSnapshot;
  victim_class:  PlayerClass;
  victim_health: number;
  victim_stance: StanceSnapshot;
}

interface DamageEvent extends GamelogEventBase {
  group:         "player";
  label:         "damage";
  killer:        Guid | "WORLD";
  victim:        Guid;
  damage:        number;
  damage_flags:  number;
  weapon:        number;
  hit_region:    HitRegion;
  killer_health: number | null;
  killer_class:  PlayerClass | null;
  killer_pos:    Position | null;
  killer_stance: StanceSnapshot | null;
  victim_health: number;
  victim_class:  PlayerClass;
  victim_pos:    Position;
  victim_stance: StanceSnapshot;
}

interface ReviveEvent extends GamelogEventBase {
  group:  "player";
  label:  "revive";
  player: Guid;  // medic
  victim: Guid;  // revived player
}

interface ClassChangeEvent extends GamelogEventBase {
  group:  "player";
  label:  "class_change";
  player: Guid;
  class:  PlayerClass;
}

interface MessageEvent extends GamelogEventBase {
  group:      "player";
  label:      "message";
  player:     Guid;
  command:    ChatCommand;
  message:    string;
  vsay_text?: string;  // only present for vsay commands with custom text
}

type ObjectiveLabel = "obj_planted" | "obj_defused" | "obj_destroyed" | "obj_repaired"
                    | "obj_taken"   | "obj_secured" | "obj_returned"  | "obj_carrierkilled";

interface ObjectiveEvent extends GamelogEventBase {
  group:     "player";
  label:     ObjectiveLabel;
  player:    Guid;
  objective: string;
}

interface FlagCapturedEvent extends GamelogEventBase {
  group:  "player";
  label:  "obj_flag_captured";
  player: Guid;
  flag:   string;
}

interface PickupEvent extends GamelogEventBase {
  group:  "player";
  label:  "pickup";
  player: Guid;
  item:   string;
  owner?: Guid;
  pos:    Position | null;
  stance: StanceSnapshot | null;
  owner_pos:     Position | null;
  owner_stance:  StanceSnapshot | null;
}

interface ShoveEvent extends GamelogEventBase {
  group:  "player";
  label:  "shove";
  player: Guid;  // shover
  victim: Guid;  // shoved
}

interface WeaponFireEvent extends GamelogEventBase {
  group:  "player";
  label:  "weapon_fire";
  player: Guid;
  weapon: number;   // et.WP_* constant value
  pos:    Position;
  pitch:  number;   // degrees, 1 decimal place
  yaw:    number;
  stance: StanceSnapshot;
}

interface RoundStartEvent extends GamelogEventBase { group: "server"; label: "round_start"; }
interface RoundEndEvent   extends GamelogEventBase { group: "server"; label: "round_end";   }

type GamelogEvent =
  | SpawnEvent | KillEvent | SuicideEvent | TeamkillEvent | DamageEvent
  | ReviveEvent | ClassChangeEvent | MessageEvent
  | ObjectiveEvent | FlagCapturedEvent | PickupEvent | ShoveEvent
  | WeaponFireEvent
  | RoundStartEvent | RoundEndEvent;

// ─── metadata ──────────────────────────────────────────────────────────────

interface MatchInfoFeatures {
  auto_rename?: boolean;
  auto_sort?:   boolean;
  auto_start?:  boolean;
  auto_map?:    boolean;
  auto_config?: boolean;
  auto_scores?: boolean;
}

interface MatchInfoScoresRound {
  map_num:    number;
  round_num:  1 | 2;
  winner:     "alpha" | "beta";
  winner_et:  TeamNumber;
  alpha_side: TeamNumber;
  fullhold:   boolean;
}

interface MatchInfoScores {
  alpha:          number;
  beta:           number;
  alpha_teamname: string | null;
  beta_teamname:  string | null;
  completed_maps: number;
  match_finished: boolean;
  match_winner:   "alpha" | "beta" | "draw" | null;
  round:          MatchInfoScoresRound;
}

interface Metadata {
  servername:    string;
  config:        string;
  stats_version: string;
  mod_version:   string;
  et_version:    string;
  server_ip:     string;
  server_port:   string;
  matchID:       string;
  features?:     MatchInfoFeatures;  // absent when no gather features active
  scores?:       MatchInfoScores;    // absent when AUTO_SCORES off or no rounds yet
}

// ─── Root payload ──────────────────────────────────────────────────────────

interface GameStatsPayload {
  round_info:   RoundInfo;
  player_stats: PlayerStats;
  metadata?:    Metadata;     // always present when scores module is loaded
  gamelog?:     GamelogEvent[];  // absent when COLLECT_GAMELOG = false
}
```

---

## Configuration

All settings are in the `CONFIGURATION` block at the top of `luascripts/stats.lua`.
No other file needs to be edited.

### [API]

| Variable | Default | Description |
|----------|---------|-------------|
| `API_TOKEN` | `"GameStatsWebLuaToken"` | Bearer token sent with every API request |
| `API_URL_MATCHID` | `"https://…/match-manager"` | Endpoint that returns `{ match_id, match: { … } }` for a given `ip/port` |
| `API_URL_SUBMIT` | `"https://…/stats/submit"` | POST endpoint that receives the final JSON payload |
| `API_URL_VERSION` | `"https://…/stats/version"` | GET endpoint that returns `{ version }` |

The match-ID endpoint is called as `GET {API_URL_MATCHID}/{server_ip}/{server_port}`.

### [PATHS]

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_FILEPATH` | `"/legacy/homepath/…/game_stats.log"` | Absolute path for the log file. Shared convention with `tracker.lua` and `combinedfixes.lua` — all three can point at the same file. |
| `JSON_FILEPATH` | `"/legacy/homepath/…/stats/"` | Directory where local JSON dumps are written when `DUMP_STATS_DATA = true` |

### [COLLECTION]

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGGING_ENABLED` | `true` | Enable/disable the log file entirely |
| `LOG_LEVEL` | `"info"` | `"info"` logs key lifecycle events. `"debug"` logs every per-event trace (verbose, high volume — only use for troubleshooting). |
| `COLLECT_GAMELOG` | `true` | Record the in-round event timeline. Disabling this also suppresses kills, damage, chat, objectives, revives, class changes, and shoves from the output. |
| `COLLECT_WEAPON_FIRE` | `false` | Record every weapon shot (`weapon_fire` gamelog events). **Very high volume** — one entry per bullet/shell fired by every player. Only enable for short controlled analysis sessions, never in normal production use. Covers both player weapons and fixed MG42s. |
| `COLLECT_OBJ_STATS` | `true` | Objective stats in `player_stats` (plant/defuse/destroy/etc.) |
| `COLLECT_SHOVE_STATS` | `true` | Shove tracking in `player_stats` and `gamelog` |
| `COLLECT_MOVEMENT_STATS` | `true` | Distance travelled and speed in `player_stats` |
| `COLLECT_STANCE_STATS` | `true` | Stance-time breakdown in `player_stats` |

### [OUTPUT]

| Variable | Default | Description |
|----------|---------|-------------|
| `DUMP_STATS_DATA` | `false` | Write an indented local JSON file to `JSON_FILEPATH` after each round. File name: `stats-{matchID}-{datetime}-{map}-round-{N}.json` |
| `SUBMIT_TO_API` | `true` | Submit stats to `API_URL_SUBMIT`. Set `false` to write locally only (useful for debugging with `DUMP_STATS_DATA = true`). |

### [GATHER FEATURES]

Gather features only activate when the match-manager API returns a route for this server with
the corresponding flag set (`auto_rename`, `auto_sort`, `auto_start`). They have no effect on ng (non-gather) matches.

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_RENAME` | `false` | Enforce team roster names from the match-manager API. Names are populated after WAITING_REPORT; the module re-polls until they arrive. |
| `AUTO_SORT` | `false` | Assign connecting spectators to their roster team during GS_WARMUP only. Never moves players already in team 1 or 2. |
| `AUTO_START` | `false` | Countdown to `scheduled_start` from match data and force-start via `ref allready`. Includes a late-join 5-second countdown if all players arrive after the scheduled time. |
| `AUTO_MAP` | `false` | Automatically switch to the next map in the match rotation after round 2 intermission ends. |
| `AUTO_CONFIG` | `false` | Apply server config via `ref config <name>` based on roster player count at map 1 round 1 warmup. |
| `AUTO_SCORES` | `false` | Track match scores using ET stopwatch rules. Active for **gather matches** (requires `auto_scores=true` in match data, BO3 termination enforced) and **ng matches** (always-on when no gather match is active, scores accumulate indefinitely). Embeds current score state into stats submissions as `metadata.scores`. Announces score in chat during intermission. |
| `VERSION_CHECK` | `true` | Check `API_URL_VERSION` at startup and broadcast a chat warning if outdated |

### [AUTO-CONFIG MAP]

Maps total registered player count to a server config name, applied once via `ref config <name>` at the start of map 1 round 1 warmup. `AUTO_CONFIG` must be enabled. Resolution selects the smallest threshold that is ≥ the actual player count.

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_CONFIG_MAP[2]` | `"legacy1"` | Config for 1–2 player matches |
| `AUTO_CONFIG_MAP[4]` | `"legacy3"` | Config for 3–4 player matches |
| `AUTO_CONFIG_MAP[6]` | `"legacy3"` | Config for 5–6 player matches |
| `AUTO_CONFIG_MAP[10]` | `"legacy5"` | Config for 7–10 player matches |
| `AUTO_CONFIG_MAP[12]` | `"legacy6"` | Config for 11–12 player matches |

Player count is taken from the registered gather roster (`alpha_team` + `beta_team` in the match-manager route), not from connected players. If no threshold matches and the API provided a `server_config` value, that is used as fallback.

### [AUTO-START TIMING]

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_START_WAIT_INITIAL` | `420` | Seconds before force-start on the first round of a match (map 1, round 1). |
| `AUTO_START_WAIT` | `180` | Seconds before force-start on all subsequent rounds. |

### [TIMING]

| Variable | Default | Description |
|----------|---------|-------------|
| `STORE_TIME_INTERVAL` | `5000` | Milliseconds between weapon-stats snapshots during a round |
| `SAVE_STATS_DELAY` | `3000` | Milliseconds to wait after intermission starts before submitting stats (avoids lag at the exact transition) |

### [ENV OVERRIDES]

Any setting can be overridden at startup via environment variable. Unset variables are
silently ignored and the defaults above apply.

| Env var | Overrides |
|---------|-----------|
| `STATS_API_TOKEN` | `API_TOKEN` |
| `STATS_API_URL_SUBMIT` | `API_URL_SUBMIT` |
| `STATS_API_URL_MATCHID` | `API_URL_MATCHID` |
| `STATS_API_URL_VERSION` | `API_URL_VERSION` |
| `STATS_API_PATH` | `JSON_FILEPATH` |
| `STATS_API_LOG_LEVEL` | `LOG_LEVEL` |
| `STATS_API_LOG` | `LOGGING_ENABLED` (`"true"` / `"false"`) |
| `STATS_API_GAMELOG` | `COLLECT_GAMELOG` |
| `STATS_API_OBJSTATS` | `COLLECT_OBJ_STATS` |
| `STATS_API_SHOVESTATS` | `COLLECT_SHOVE_STATS` |
| `STATS_API_MOVEMENTSTATS` | `COLLECT_MOVEMENT_STATS` |
| `STATS_API_STANCESTATS` | `COLLECT_STANCE_STATS` |
| `STATS_API_WEAPON_FIRE` | `COLLECT_WEAPON_FIRE` |
| `STATS_API_DUMPJSON` | `DUMP_STATS_DATA` |
| `STATS_SUBMIT` | `SUBMIT_TO_API` |
| `STATS_GATHER_FEATURES` | Shortcut: sets all gather flags (`AUTO_RENAME`, `AUTO_SORT`, `AUTO_START`, `AUTO_MAP`, `AUTO_CONFIG`, `AUTO_SCORES`) to `true` when `"true"`. Individual flags still apply when unset or `"false"`. |
| `STATS_AUTO_RENAME` | `AUTO_RENAME` |
| `STATS_AUTO_SORT` | `AUTO_SORT` |
| `STATS_AUTO_START` | `AUTO_START` |
| `STATS_AUTO_MAP` | `AUTO_MAP` |
| `STATS_AUTO_CONFIG` | `AUTO_CONFIG` |
| `STATS_AUTO_SCORES` | `AUTO_SCORES` |
| `STATS_AUTO_START_WAIT_INITIAL` | `AUTO_START_WAIT_INITIAL` |
| `STATS_AUTO_START_WAIT` | `AUTO_START_WAIT` |
| `STATS_AUTO_CONFIG_2` | `AUTO_CONFIG_MAP[2]` — server config name for ≤2-player matches |
| `STATS_AUTO_CONFIG_4` | `AUTO_CONFIG_MAP[4]` — server config name for ≤4-player matches |
| `STATS_AUTO_CONFIG_6` | `AUTO_CONFIG_MAP[6]` — server config name for ≤6-player matches |
| `STATS_AUTO_CONFIG_10` | `AUTO_CONFIG_MAP[10]` — server config name for ≤10-player matches |
| `STATS_AUTO_CONFIG_12` | `AUTO_CONFIG_MAP[12]` — server config name for ≤12-player matches |
| `STATS_API_VERSION_CHECK` | `VERSION_CHECK` |

---

## config.toml

`luascripts/config.toml` contains **only** map-specific objective patterns and common
buildable patterns. API credentials, paths, and feature flags have been removed from it.

### Common buildables

Buildables shared across all maps (command post, MG nest). Each has `construct` and `destruct`
pattern arrays, plus a `plant` array for dynamite attribution.

```toml
[common_buildables.command_post.patterns]
construct = ["command post constructed"]
destruct   = ["command post destroyed"]
plant      = ["planted at the command post"]
```

### Map sections

Each map is declared under `[maps.<mapname>]`. Supported sub-sections:

| Section | Keys | Description |
|---------|------|-------------|
| `objectives.<name>` | `steal_pattern`, `secured_pattern`, `return_pattern` | Flag/document steal+secure cycle |
| `buildables.<name>` | `construct_pattern`, `destruct_pattern`, `plant_pattern` | Map-specific constructibles |
| `buildables.<name>` | `enabled = true` | Marks a common buildable as present on this map |
| `flags.<name>` | `flag_pattern`, `flag_coordinates` | Checkpoint / flag capture attribution |
| `misc.<name>` | `misc_pattern`, `misc_coordinates` | Coordinate-based misc objective |
| `escort.<name>` | `escort_pattern`, `escort_coordinates` | Coordinate-based vehicle escort event |

---

## Gather features

All gather features require the match-manager API to return a route for this server with
the corresponding flag set. They have no effect on ng (non-gather) matches.

### AUTO_RENAME

Enforces player names against the roster returned by the match-manager API:

1. **Warmup** — API is polled when the first player readies up. Team data is cached in
   `luascripts/team_data.json`. If names are not yet populated (gather phase 1 — before
   WAITING_REPORT), the module stays stale and re-polls until `auto_rename=true` arrives.
2. **Warmup countdown** — API is called again for a fresh fetch; all current players are
   validated.
3. **GS_PLAYING** — team data is loaded from the local file only (no API calls during a
   live round). Names are re-checked every 5 seconds.
4. **Intermission** — team data file is wiped so stale data does not survive into the next
   match.

Spectator names are prefixed with `spectator_teamname` from the API response (if present),
truncated to 35 characters.

### AUTO_SORT

Assigns a connecting player to their roster team on connect, during GS_WARMUP only.
Only moves players currently in spectator (team 3). Never touches players already in
team 1 (Axis) or team 2 (Allies). Respects `sides_swapped` from match data.

### AUTO_START

Runs a countdown to `scheduled_start` (Unix timestamp from match data) and calls
`ref allready` when all roster players are present. If the match fails to start (missing
players), a notification is sent to the API. If all players join after the scheduled time
while still in GS_WARMUP, a 5-second late-join countdown triggers automatically.

### AUTO_SCORES

Tracks match scores using ET stopwatch rules. Operates in two modes depending on whether a
gather match is active:

**Gather mode** — activated when `AUTO_SCORES=true` and the match-manager route carries
`is_gather=true`. Enforces BO3 termination (match ends at 3 pts or after map 3). Score state
persists across round resets (wiped only on a new `match_id`).

**ng (non-gather) mode** — activated when `AUTO_SCORES=true` and the route does not carry
`is_gather=true` (scrims, tournaments, public matches). Scores accumulate indefinitely with no
BO3 termination. Match identity is maintained across `et_InitGame` restarts via GUID
continuity: if ≥65% of the in-team GUIDs from round 1 are still present at round 2 start, the
match continues; otherwise a new match is started. State is persisted to
`{match_id}_team_data.json` between restarts.

Both modes embed the current score state into every stats submission under `metadata.scores` and announce the score in chat during intermission.


Scoring rules (both modes):

- **Map win** (team wins both rounds): +2 pts to winner
- **Map draw** (split 1-1): +1 pt each
- **Fullhold** (`timelimit == nextTimeLimit`): defending team gets provisional +1 after r1
  - **Double fullhold** (both teams hold): provisional removed, +1 each
  - **Normal r2 after r1 fullhold**: provisional removed, normal result applied
- **Clinch** (only possible at 2-0 + r1 fullhold provisional = 3-0): match ends before r2 *(gather only)*

Team-side validation (gather mode): connected player GUIDs are matched against the alpha
roster from match data. If ≥80% of matched players are on the expected ET team, the assignment
is confirmed; otherwise the detected side is used. Falls back to the static side table if
detection is inconclusive.

Possible final scores (gather): **3-0** (clinch), **4-0**, **3-1**, **4-2**, **3-3** (draw).

---

### Required Lua libraries

Both must be available to the ETLegacy Lua runtime (present in `lualibs/`):

- `dkjson` — JSON encode/decode
- `toml` — TOML parser

---

## File structure

```
luascripts/
├── stats.lua                   ← entry point + configuration
├── config.toml                 ← map patterns only
└── stats/
    ├── util/
    │   ├── log.lua             timestamped file logger (info / debug levels)
    │   ├── http.lua            async/sync curl helpers
    │   └── utils.lua           strip_colors, normalize, sanitize, distance, get_connected_players, …
    ├── config.lua              TOML loader
    ├── players.lua             GUID cache, get_snapshot(), class-switch detection
    ├── movement.lua            per-frame stance + distance + speed tracking
    ├── gamelog.lua             in-memory event buffer
    ├── events.lua              et_Obituary, et_Damage, et_ClientCommand
    ├── objectives.lua          et_Print pattern matching, buildables, flags, shoves
    ├── gather.lua              gather features: auto_rename, auto_sort, auto_start, auto_scores
    ├── api.lua                 match-ID fetch, version check
    ├── scores.lua              match score tracking (gather + ng modes)
    ├── ng_scores.lua           ng match lifecycle: GUID continuity, persistence, roster
    ├── stats.lua               StoreStats, SaveStats, JSON assembly
    └── gamestate.lua           GS change detection, intermission countdown, reset
```
