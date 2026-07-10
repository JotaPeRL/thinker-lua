# Plano de Implementação — IA do Thinker em Lua

Objetivo: extrair a IA determinística do Thinker Mod (hoje escrita em C++ dentro de
`thinker.dll`) para scripts Lua executados por um interpretador embutido na DLL,
mantendo o comportamento atual como baseline e abrindo caminho para desenvolvimento
de IA aprimorada sem recompilar o mod.

**Escopo:**

- Compilar o projeto no Arch Linux (cross-compile mingw32) e rodar via Wine.
- Embutir um interpretador Lua (recomendação: LuaJIT, ver Fase 2).
- Portar os módulos de decisão da IA de C++ para Lua, de forma incremental e
  verificável, com fallback para o código C++ original.

**Fora de escopo (não mexer):**

- Correções de bugs do engine, patches do Scient, renderização, mapgen, UI,
  launcher, netcode. Tudo isso permanece em C++.
- Mudanças de balanceamento/comportamento da IA. O porte deve ser 1:1 no início;
  melhorias de IA vêm depois, em cima da base Lua.

---

## Contexto arquitetural (como a IA funciona hoje)

O Thinker é uma DLL (`thinker.dll`) injetada no `terranx.exe` (binário 32-bit
Windows). Em `DllMain`/`ThinkerModule` (`src/main.cpp:442`), o mod lê `thinker.ini`
e aplica patches em memória (`src/patch.cpp`), redirecionando `call`s do engine
para funções do mod via `write_call(endereço, função)`. A IA do Thinker é ativada
por facção conforme `factions_enabled` (`src/faction.cpp:143`).

Pontos de entrada da IA (os "seams" onde o Lua vai se encaixar):

| Domínio | Entrada C++ | Arquivos | Tamanho |
|---|---|---|---|
| Dispatch de turno/unidade | `mod_enemy_turn`, `mod_enemy_veh`, `mod_enemy_move` | `veh_turn.cpp` | ~900 loc |
| Movimento por tipo de unidade | `colony_move`, `former_move`, `crawler_move`, `artifact_move`, `trans_move`, `nuclear_move`, `combat_move`, `move_upkeep` | `move.cpp` | ~3700 loc |
| Planos estratégicos | `plans_upkeep`, `design_units`, `former_plans`, `invasion_plan`, `land_raise_plan` | `plan.cpp`, `move.cpp` | ~600 loc |
| Produção das bases | `select_build`, `find_proto`, `unit_score`, `facility_score`, `find_project`, `mod_base_hurry` | `build.cpp`, `plan.cpp` | ~1300 loc |
| Engenharia social / diplomacia | `mod_social_ai`, `mod_wants_to_attack` | `faction.cpp` | ~2500 loc (parcial) |
| Pesquisa | `mod_tech_ai`, `mod_tech_val` | `tech.cpp` | ~760 loc |
| Goals | `add_goal`, `wipe_goals` etc. (estado no struct `Faction` do engine) | `goal.cpp` | ~180 loc |
| Pathfinding e busca de tiles | `Path`, `TileSearch`, `PMTable mapdata`, `NodeSet mapnodes` | `path.cpp`, `map.cpp`, `move.h` | ~1000 loc |

Infraestrutura relevante:

- Estruturas do engine (VEH, BASE, Faction, MAP, UNIT, regras de `alphax.txt`)
  já estão 100% mapeadas em `engine_types.h`, `engine_veh.h`, `engine_base.h`,
  `engine.h` — endereços fixos de globais tipo `Vehs`, `Bases`, `Factions`,
  `MapTiles`.
- RNG: a IA usa o RNG do próprio engine (`game_rand`, `src/random.cpp`) e um LCG
  próprio (`random(n)`). Determinismo importa para replays/sync multiplayer.
- Logging: `debug.txt` via `debug()`/`debug_ver()`; crash handler próprio.

**Total a portar: ~9–10 mil linhas de C++ de lógica de decisão.** Pathfinding e
estruturas de dados quentes (PMTable) ficam em C++ como primitivas expostas ao Lua
(ver Fase 4).

---

## Fase 0 — Preparação do fork

> **Status: ✅ concluída em parte (2026-07-10)** — remote `upstream` configurado,
> branch `lua-ai` criada. Pendente: adicionar o remote `origin` quando o fork
> subir ao GitHub (ver instruções no fim da Fase 0).

1. Configurar remotes: `origin` = seu fork; `upstream` = `induktio/thinker`.
2. Criar branch de trabalho `lua-ai` a partir de `master`.
3. Estratégia de convivência com upstream: o Thinker é ativamente desenvolvido
   (rewrites grandes, ex.: commit `15418b2 "Rewrite faction and movement code"`).
   Para minimizar conflitos de rebase:
   - Concentrar o código novo em arquivos novos (`src/luaai.cpp`, `src/luaapi.cpp`,
     diretório `lua/`), tocando o mínimo possível nos arquivos existentes.
   - Nos arquivos existentes, o toque é de 1–3 linhas por função hookada
     (o "seam" da Fase 4).
4. Documentar no `Readme.md` do fork o objetivo e o status.

**Critério de conclusão:** fork buildando idêntico ao upstream, branch criada.

---

## Fase 1 — Build no Arch Linux + execução via Wine

> **Status: ✅ concluída (2026-07-10)** — builds `develop` e `debug` compilam
> limpas (GCC mingw 16.1.0, CMake 4.3.4, Ninja 1.13.2); jogo GOG instalado em
> `~/.wine-smac/drive_c/Games/SMAC` (terranx.exe v2.0, SHA-1 confirmado);
> `tools/deploy.sh` criado; jogo lança normalmente via Wine com o mod carregado.

O projeto já suporta cross-compile com mingw-w64 i686 via CMake
(`CMakeLists.txt` fixa `i686-w64-mingw32-g++`; presets em `CMakePresets.json`).

### Comandos do dia a dia (validados)

```sh
# Build develop (otimizada, link estático)
cmake --preset ninja-develop            # configurar (1ª vez)
cmake --build --preset ninja-develop    # artefatos em build/develop/

# Build debug (BUILD_DEBUG: atalhos de dev Alt+D/M/V, debug.txt verboso)
cmake --preset ninja-debug              # configurar (1ª vez)
cmake --build --preset ninja-debug      # artefatos em build/debug/

# Deploy para a pasta do jogo (copia dll/exe, modmenu.txt, basenames/;
# a build debug copia também as DLLs de runtime do mingw)
tools/deploy.sh develop                 # ou: tools/deploy.sh debug

# Lançar o jogo
WINEPREFIX=~/.wine-smac wine ~/.wine-smac/drive_c/Games/SMAC/thinker.exe -windowed
```

### 1.1 Toolchain

```sh
sudo pacman -S --needed mingw-w64-gcc cmake ninja wine
```

Notas Arch-específicas:

- O pacote `mingw-w64-gcc` do Arch fornece os dois triplets, incluindo
  `i686-w64-mingw32-g++` — confirmar com `i686-w64-mingw32-g++ --version`.
- `cmake_minimum_required(VERSION 3.31)` — ok, Arch tem CMake recente.
- Wine do Arch roda binários 32-bit (WoW64/multilib). Habilitar `[multilib]`
  no `pacman.conf` se ainda não estiver (necessário também para o LuaJIT, Fase 2).

### 1.2 Build

```sh
cmake --preset ninja-develop
cmake --build --preset ninja-develop
# artefatos: build/ninja-develop/thinker.dll e thinker.exe
```

Builds a validar: `debug` (com `BUILD_DEBUG`, atalhos de desenvolvedor Alt+D/M/V
etc., essenciais para as fases seguintes) e `develop`.

Resultados observados no build real:

- GCC mingw 16.1.0 do Arch compila os dois presets **sem nenhum warning**.
- O mingw do Arch linka contra **UCRT** (imports `api-ms-win-crt-*`), diferente
  do toolkit msvcrt citado no `Technical.md` upstream. Transparente no Wine
  (ucrtbase embutido) e em Windows 10+; só quebraria em XP.
- A build `debug` **não é estática** (`-static` só se aplica a develop/release):
  depende de `libgcc_s_dw2-1.dll`, `libstdc++-6.dll` e `libwinpthread-1.dll`,
  copiadas de `/usr/i686-w64-mingw32/bin/` pelo `deploy.sh`.

### 1.3 Instalação e teste no Wine

Como foi feito (prefixo em `~/.wine-smac`, jogo em `drive_c/Games/SMAC`):

1. O Wine ≥ 11 do Arch é **WoW64-only**: `WINEARCH=win32` não é mais suportado.
   Usar prefixo padrão — binários 32-bit rodam via WoW64 normalmente:
   `WINEPREFIX=~/.wine-smac wineboot -u`.
2. Instalador GOG (Inno Setup) em modo silencioso:
   `WINEPREFIX=~/.wine-smac wine setup_...exe /VERYSILENT /SUPPRESSMSGBOXES
   /NORESTART /SP- /LANG=english '/DIR=C:\Games\SMAC'`.
   Verificar o `terranx.exe` v2.0
   (SHA-1 `4b19c1fe3266b5ebc4305cd182ed6e864e3a1c4a` — confirmado).
3. Deploy com `tools/deploy.sh [develop|debug]`. **Atenção:** além de
   `thinker.dll`/`thinker.exe`, o mod exige `docs/modmenu.txt` na pasta do jogo
   (define todos os diálogos do Thinker, inclusive Alt+T) e usa
   `docs/basenames/`. O `deploy.sh` copia ambos; `docs/alphax.txt` (mudanças de
   regras opcionais) e `docs/smac_mod/` são deixados de fora de propósito.
4. Lançar e validar (feito): jogo abre em modo janela, mod carregado, Alt+T ok.
   Notas de Wine: `WINEDEBUG=-all` para performance; a versão GOG
   `1.1_pracx_ddraw` traz `ddraw.dll` e PRACX na pasta — não interferiram no
   teste, mas remover/renomear `ddraw.dll` é a primeira coisa a tentar se houver
   problema gráfico.

### 1.4 CI (opcional, mas recomendado)

GitHub Actions em `ubuntu-latest` com `g++-mingw-w64-i686-posix` + CMake,
buildando `develop` a cada push. Garante que o fork não quebra o build enquanto
o porte avança.

**Critério de conclusão:** jogo roda via Wine com o `thinker.dll` compilado
localmente, menu Alt+T visível, partida jogável por 50+ turnos sem crash.

---

## Fase 2 — Embutir o interpretador Lua

### 2.1 Escolha do interpretador: **LuaJIT 2.1** (recomendado)

| Critério | LuaJIT 2.1 | Lua 5.4 (PUC) |
|---|---|---|
| Alvo x86 32-bit Windows | Plataforma original do LuaJIT, excelente suporte | OK |
| Performance | Próxima de C com JIT (importante p/ `move_upkeep`/scoring por tile) | 2–10x mais lento |
| **FFI** | **Acessa structs do engine direto na memória, sem camada de binding manual** | Não tem; exigiria centenas de bindings C manuais |
| Chamada de funções do engine em endereço fixo | `ffi.cast` com suporte a `__cdecl`/`__stdcall`/`__thiscall` em x86 | Exige wrapper C por função |
| Build | Cross-compile com passo extra (host multilib) | Trivial (vendorar .c no glob do CMake) |
| Linguagem | Lua 5.1 + extensões | Lua 5.4 (goto, inteiros nativos) |

O FFI é o fator decisivo: o jogo é um processo 32-bit com todas as estruturas já
mapeadas em headers; com LuaJIT o Lua lê/escreve `Vehs[i]`, `Bases[i]`, `MAP*`
diretamente, e chama funções do engine por endereço. Isso reduz a camada de
binding de "milhares de linhas de glue C" para "declarações cdef geradas dos
headers". A performance do JIT também elimina o risco nos loops quentes
(varreduras de mapa 128x128+ por fação por turno).

Fallback documentado: se o LuaJIT se mostrar problemático sob Wine (improvável —
é amplamente usado em jogos Windows 32-bit), trocar por Lua 5.4 vendorado exige
refazer só a camada de binding (Fase 3), não os scripts de IA — por isso a Fase 3
define uma API de alto nível que isola o resto dos scripts do mecanismo FFI.

### 2.2 Build do LuaJIT

1. Vendorar o LuaJIT como submódulo git em `third_party/luajit` (branch v2.1).
2. Cross-compile para Windows i686, link estático:

```sh
# requer multilib no Arch: sudo pacman -S --needed multilib-devel lib32-glibc
make -C third_party/luajit/src HOST_CC="gcc -m32" \
     CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
```

   (O host build de `minilua`/`buildvm` precisa do mesmo tamanho de ponteiro do
   alvo — daí o `gcc -m32` e o multilib.)
3. Integrar no CMake: alvo `ExternalProject`/`add_custom_command` que roda o make
   acima e produz `libluajit.a`; `target_link_libraries(thinkerlib PRIVATE luajit)`
   + include dir. Documentar em `Technical.md` do fork.
4. Smoke test: `luaL_dostring(L, "return 1+1")` chamado no startup, resultado no
   `debug.txt`.

### 2.3 Ciclo de vida e layout

- **Init:** em `ThinkerModule`/`DllMain` (`src/main.cpp:442`), após `patch_setup`
  e leitura do `thinker.ini`: criar `lua_State`, abrir libs padrão + ffi, e
  carregar `lua/init.lua` do diretório do jogo. Novo par de arquivos
  `src/luaai.cpp/.h` encapsula tudo (estado, pcall wrappers, reload).
- **Layout de scripts** (instalados junto do jogo, distribuídos no zip de release):

```
<pasta do jogo>/
  thinker.dll
  lua/
    init.lua          -- bootstrap, carrega módulos
    ffi/types.lua     -- cdefs gerados dos headers (Fase 3)
    ffi/funcs.lua     -- funções do engine/thinker por endereço
    api/…             -- API de alto nível (game, map, rules, rand, log)
    ai/…              -- a IA portada (tech.lua, social.lua, build.lua, move.lua…)
    test/…            -- testes unitários rodáveis fora do jogo
```

- **Config novas no `thinker.ini`:**
  - `lua_ai=1` — liga/desliga a IA em Lua globalmente (0 = comportamento C++ puro).
  - `lua_shadow=0` — modo sombra da Fase 5 (compara Lua vs C++ sem afetar o jogo).
  - `lua_strict=0` — 0: erro de Lua cai no fallback C++ e loga; 1: erro abre
    popup e encerra (para desenvolvimento).
- **Tratamento de erros:** toda chamada de hook passa por `lua_pcall` com handler
  de traceback. Erro → log completo em `debug.txt` (uma vez por função/turno para
  não inundar) → retorno "não tratado" → o C++ original executa. **O jogo nunca
  pode quebrar por causa de um script.**
- **Hot reload:** atalho de desenvolvedor (ex.: Alt+U, seguindo o padrão de
  `debug.cpp`) que descarta o `lua_State` e recarrega `lua/`. Iteração de
  desenvolvimento sem reiniciar o jogo — esse é um dos maiores ganhos do projeto.
- **Logging:** expor `log.debug(...)`/`log.ver(...)` escrevendo no mesmo
  `debug.txt`, com prefixo `lua:`, respeitando o toggle Alt+M de verbose.

**Critério de conclusão:** `thinker.dll` com LuaJIT estático linka e roda no Wine;
`init.lua` carrega, loga no `debug.txt`, hot reload funciona, erro proposital em
script não derruba o jogo.

---

## Fase 3 — Camada de bindings (FFI + API de alto nível)

Duas camadas, para que a IA em Lua nunca toque FFI cru:

### 3.1 Camada baixa: cdefs e endereços

1. **Gerador de cdefs:** script Python em `tools/gen_ffi.py` que parseia
   `engine_types.h`, `engine_veh.h`, `engine_base.h`, `engine_enums.h` e emite
   `lua/ffi/types.lua` (structs, enums e asserts de `sizeof`). Gerado, não
   escrito à mão → quando o upstream mudar um struct, regenerar. Validar no
   startup: `assert(ffi.sizeof('VEH') == 52)` etc. contra os `static_assert`
   existentes nos headers C++.
2. **Globais do engine:** tabela de endereços (ex.: `Vehs = ffi.cast('VEH*', 0x...)`)
   extraída de `engine.h`. Também gerada pelo script.
3. **Funções por endereço:** engine (`can_arty`, `veh_skip`, `set_move_to`,
   `base_find_3`, `action_...` etc.) e helpers do Thinker que permanecem em C++
   (pathfinding, PMTable). Para os helpers C++, exportar com `extern "C"` uma
   tabela de function pointers (`struct LuaHostApi`) passada ao Lua no init —
   mais robusto que depender de export de símbolos da DLL.
4. **RNG:** expor `rand.game(n)` → `game_randv(n)` e `rand.map(n)` → LCG de
   `random.cpp`. **Regra de projeto: `math.random` é proibido em `lua/ai/`**
   (o init pode até sobrescrevê-lo com erro). Isso preserva o stream de RNG do
   engine → determinismo e sync de rede idênticos ao C++.

### 3.2 Camada alta: API idiomática

Módulos Lua finos sobre o FFI, com a semântica dos helpers já existentes em
`veh.h`/`base.h`/`map.h`:

- `game`: iteradores `game.vehs()`, `game.bases()`, `game.factions()`,
  `game.turn()`, acesso a `conf`.
- `map`: `map.tile(x, y)` (com wrap do eixo X como `mapsq`), `map.range`,
  `map.iter_near(x, y, r)`, flags de tile (`is_fungus`, `items`, `region`...).
- `veh`/`base`: métodos espelhando os do C++ (`veh:triad()`, `veh:speed()`,
  `base:can_build(item)`, ...). Implementar sob demanda, conforme o porte pedir.
- `path`: wrappers das primitivas C++ mantidas (`path.find`, `path.move_to`,
  `tilesearch.iterate(...)`, leituras de `mapdata`/`mapnodes`).
- `rules`: acesso às tabelas de `alphax.txt` já parseadas (Units, Facility,
  Tech, Social).

Diretriz de determinismo: decisões nunca podem depender de ordem de iteração de
tabela hash (`pairs`). A API fornece iteradores em ordem de índice; revisar isso
em code review de cada módulo portado.

**Critério de conclusão:** de dentro do jogo, um script consegue listar bases e
unidades de uma fação, ler tiles, chamar `path.find` e obter os mesmos valores
que o `debug.txt` do C++ reporta. Asserts de layout de struct passam.

---

## Fase 4 — Porte incremental da IA

### 4.1 Mecanismo de hook (seam)

Cada ponto de entrada C++ ganha um desvio de 2–3 linhas no início:

```cpp
int select_build(int base_id) {
    int value;
    if (lua_ai_hook_i("select_build", &value, base_id)) {
        return value; // decidido pelo Lua
    }
    // ... código C++ original intocado (fallback)
}
```

`lua_ai_hook_*` (em `luaai.cpp`) retorna `false` se `lua_ai=0`, se a função não
está registrada no Lua, ou se o pcall falhou. Assim cada função migra
individualmente, e o C++ original permanece como referência e fallback durante
todo o projeto (remoção só em fase de limpeza, opcional).

Estado compartilhado durante a transição: `plans[]` (AIPlans), `mapdata`
(PMTable) e `mapnodes` continuam sendo os dados canônicos em C++, acessados pelo
Lua via FFI — os dois lados enxergam o mesmo estado, então dá para portar metade
de um domínio sem dessincronia.

### 4.2 Ordem de porte (do menor risco para o maior)

Cada item segue o mesmo ciclo: portar 1:1 → modo sombra (Fase 5.1) até zerar
divergências → ativar Lua por padrão no branch → seguir para o próximo.

1. **Piloto — IA de pesquisa** (`tech.cpp`: `mod_tech_val` scoring, `mod_tech_ai`;
   ~400 loc relevantes). Pequena, pura (score por tech), fácil de comparar.
   Valida o pipeline inteiro (hook, FFI, RNG, sombra).
2. **Engenharia social** (`faction.cpp`: `mod_social_ai` e o scoring de modelos
   sociais; `mod_wants_to_attack`). Autocontida, roda 1x por turno por fação.
3. **Produção e planos** (`build.cpp` + `plan.cpp`): `governor_priorities`,
   `facility_score`, `unit_score`/`find_proto`, `select_colony`/`select_combat`,
   `select_build`, `find_project`, `mod_base_hurry`, depois `plans_upkeep`,
   `design_units`, `former_plans`. É o coração do "desafio do single player" e
   onde melhorias futuras de IA mais pagam.
4. **Movimento** (`move.cpp` + dispatch em `veh_turn.cpp` + `goal.cpp`): começar
   pelos movers isolados (`artifact_move` → `nuclear_move` → `crawler_move` →
   `colony_move` → `former_move` → `trans_move`) e terminar em `combat_move` +
   `move_upkeep` + planos de invasão. É o maior e o mais sensível a performance.
5. **Decisões de probe da IA** (`probe.cpp`, parcial — só as escolhas de alvo/ação
   da IA; a mecânica de resolução fica em C++).

### 4.3 O que fica em C++ (primitivas expostas ao Lua)

- `path.cpp` inteiro (A*, `Path::find`, movimento tático de baixo nível).
- `TileSearch` e o preenchimento do `PMTable`/`mapdata` em `move_upkeep`
  (varreduras O(mapa) por turno). O Lua orquestra (decide *o que* fazer), o C++
  fornece consultas rápidas (*como* calcular). Se depois o LuaJIT provar
  performance suficiente, portar também — decisão adiada por medição, não por
  palpite.
- Combate em si (`veh_combat.cpp`), mecânicas do engine, tudo de UI/render.

### 4.4 Convenções do código Lua

- Um módulo por domínio (`ai/tech.lua`, `ai/social.lua`, `ai/build.lua`,
  `ai/move.lua`, `ai/plan.lua`), registrando hooks numa tabela central
  `ai.hooks` lida pelo `luaai.cpp`.
- Porte 1:1 comentado com referência à função C++ de origem (nome + arquivo),
  para auditoria enquanto o upstream evolui.
- `luacheck` no CI para pegar globais acidentais e erros bobos.

**Critério de conclusão (por módulo):** modo sombra sem divergências em N turnos
de autoplay (ver 5.1) em pelo menos 3 saves distintos + 1 partida nova com seed
fixa; sem regressão perceptível de tempo de turno.

---

## Fase 5 — Validação, testes e performance

### 5.1 Modo sombra (a ferramenta central do porte)

Com `lua_shadow=1`, o hook executa **ambas** as implementações e compara:

1. Salvar o estado dos RNGs (`game_rand_state()`, `random_state()`).
2. Rodar a versão Lua, capturar o resultado, **restaurar os RNGs** (a decisão Lua
   não pode consumir o stream duas vezes).
3. Rodar o C++ (que vale para o jogo).
4. Divergência → logar em `debug.txt`: função, argumentos, resultado de cada lado.

Restrição: funções com efeitos colaterais (ex.: `combat_move` emite ordens) não
podem rodar duas vezes; para essas, a comparação em sombra se limita às funções
de scoring puras internas, e a validação do todo é feita pelos testes de
determinismo (5.3) alternando `lua_ai` entre execuções.

### 5.2 Testes unitários fora do jogo

Os módulos `lua/ai/*` dependem só da camada `api/*`; criar `lua/test/mock/` com
implementações fake da API (mapa sintético, fações de teste) e rodar com o
`luajit` nativo do Arch (`pacman -S luajit`) + runner simples (ou `busted`).
Testes rápidos para funções de scoring (facility_score, unit_score, tech_val) com
casos extraídos de logs reais do jogo. Roda no CI.

### 5.3 Determinismo e regressão

- Harness manual/scriptado: mesma seed + mesmo save inicial, autoplay de N turnos
  (todas as fações em IA, jogador em observador/autopilot; investigar as
  facilidades do build debug — `test.cpp`/`extra_setup` — e, se preciso,
  adicionar uma flag `autoplay_turns=N` que encerra e salva sozinho).
- Comparar: hash do estado (posições de unidades, bases, tech, energia por fação,
  extraível via script Lua no fim do turno) entre duas execuções com `lua_ai=1`
  (determinismo do Lua) e entre `lua_ai=0` vs `lua_ai=1` (fidelidade do porte,
  válido enquanto o porte for 1:1).
- `debug.txt` em modo verbose diffável entre execuções.

### 5.4 Performance

- Instrumentar tempo por fase de turno (upkeep, produção, movimento) por fação,
  logado em debug. Medir baseline C++ antes do porte de movimento.
- Orçamento: turno da IA em Lua ≤ 1,5x o tempo do C++ em mapas enormes com 7
  fações no late game (o alvo real é "imperceptível a olho").
- Ferramentas: `jit.p` (profiler do LuaJIT) embutível via script; conferir se
  loops quentes não caem para o interpretador (`jit.v`/`jit.dump` em builds de
  desenvolvimento).

### 5.5 Compatibilidade

- Saves: o porte não muda formato de save (estado da IA já vive nos structs do
  engine/`plans[]`). Validar load de saves vanilla e de Thinker C++.
- Multiplayer: fora de escopo validar a fundo, mas manter a regra de RNG (3.1) e
  registrar em doc que `lua_ai` precisa ser idêntico entre os peers.
- Windows nativo: pedir smoke test à comunidade/amigo com Windows real antes de
  qualquer release (Wine é o ambiente de dev, não o único alvo).

---

## Fase 6 — Documentação, empacotamento e DX

1. `docs/LUA_API.md`: referência da API (`game`, `map`, `veh`, `base`, `path`,
   `rules`, `rand`, `log`) + ciclo de vida dos hooks + regras (RNG, determinismo,
   proibições).
2. `docs/LUA_PORTING.md`: mapa função C++ → módulo Lua, status por módulo
   (checklist do porte), como usar modo sombra e hot reload.
3. Atualizar `Technical.md` do fork: build no Arch, LuaJIT, deploy via Wine.
4. Empacotamento: incluir `lua/` nos zips (`tools/makedevzip.sh`,
   `tools/makerelzip.sh`) e no `deploy.sh`.
5. Exemplo "hello AI": script mínimo comentado que sobrescreve um hook simples,
   como porta de entrada para outros modders — esse é o produto final do fork.

---

## Riscos e mitigações

| Risco | Impacto | Mitigação |
|---|---|---|
| FFI sem memory safety: cdef errado corrompe memória do jogo | Crash difícil de depurar | cdefs gerados + asserts de `sizeof`/offset no startup; crash handler já loga em `debug.txt`; builds debug com verificações extras |
| Upstream do Thinker faz rewrites grandes | Rebase doloroso | Seams mínimos e centralizados; código novo em arquivos novos; regenerar cdefs por script |
| Performance do movimento em Lua | Turnos lentos no late game | Pathfinding/PMTable ficam em C++; LuaJIT; medir antes/depois; portar movimento por último |
| Divergência comportamental silenciosa | IA "diferente" sem perceber | Modo sombra por função; testes de determinismo com seed fixa; porte 1:1 auditável |
| LuaJIT + Wine/32-bit edge cases | Bloqueio na Fase 2 | Smoke test cedo (Fase 2 termina com Lua rodando in-game); fallback Lua 5.4 documentado, isolado pela camada de API |
| RNG consumido de forma diferente | Dessync/replays quebrados | `rand.*` obrigatório, `math.random` banido, snapshot/restore no modo sombra |

---

## Marcos

- **M1 — Build local:** ✅ concluído (2026-07-10) — jogo roda via Wine com DLL compilada no Arch.
- **M2 — Lua embutido:** Fase 2 completa (init.lua, erro seguro, hot reload).
- **M3 — Bindings:** Fase 3 completa (script lê estado do jogo e chama primitivas).
- **M4 — Piloto:** IA de pesquisa em Lua ativa por padrão, sombra limpa.
- **M5 — Produção/social em Lua:** módulos 2 e 3 da ordem de porte ativos.
- **M6 — Movimento em Lua:** porte completo; C++ vira fallback legado.
- **M7 — Release do fork:** docs, zips com `lua/`, exemplo de customização.

A partir de M4 o fork já é útil (dá para experimentar IA de pesquisa custom); cada
marco seguinte amplia a superfície modificável sem esperar o projeto inteiro.
