# SPEC — Bot de atendimento WhatsApp do Divercity Park ("Dry")

Workflow único no n8n (modo queue, com Redis), usando os nodes nativos do pacote oficial do WAHA para n8n.
Escopo da v1: atender **somente números que não estão na agenda do celular**, responder preço de passaporte e horário de funcionamento; todo o resto vai para atendente humana.

## 0. Regras de construção (valem para tudo)

1. **Um workflow só**, organizado em blocos numerados. Cada bloco tem um Sticky Note com título e uma linha dizendo o que ele faz, envolvendo os nodes do bloco. Nodes nomeados com prefixo do bloco (`2.1 Filtrar chat`, `3.2 Pausar chat`...).
2. **Nodes do WAHA: sempre os nativos** (WAHA Trigger e WAHA: Send Seen, Start Typing, Send Text, Stop Typing, consulta de contato). **Proibido HTTP Request ou Webhook genérico para falar com o WAHA.** Conferir na instalação quais operações existem; não inventar nomes. Se faltar uma operação necessária (ex.: consultar contato), **parar e avisar o dono**, sem improvisar com HTTP.
3. **Nada hardcoded.** Todo valor que muda entre teste e produção fica em um dos dois nodes Set do bloco 1. Os demais nodes só leem de lá via `$('CONFIG')` e `$('INSTRUCOES')`.
4. **Segredos:** a credencial do WAHA (URL e API key) e a da OpenAI ficam em Credentials do n8n (os nodes exigem). O token da API do site fica no CONFIG, por decisão do dono, para trocar fácil. **Não escrever o token real neste arquivo nem em nenhum arquivo do repositório.**
5. **O bot nunca inventa preço, horário ou regra.** Falha, resposta vazia ou dúvida viram handoff.
6. Fuso: tudo que depende de data/hora usa `America/Sao_Paulo` explicitamente no código, e a instância n8n sobe com `GENERIC_TIMEZONE=America/Sao_Paulo`.

## 1. Bloco CONFIG e INSTRUÇÕES (dois nodes Set)

### 1.1 `CONFIG` (técnico, só o dono mexe)

| Campo | Valor inicial | Observação |
|---|---|---|
| `API_BASE_URL` | `https://www.divercitypark.com.br/api/v1` | |
| `SITE_API_TOKEN` | `COLE_O_TOKEN_AQUI` | enviado como `Authorization: Bearer <token>` |
| `PATH_PRECOS` | `/content/prices` | |
| `PATH_HORARIOS` | `/content/hours` | |
| `WAHA_SESSION` | `default` | preencher |
| `GRUPO_ATENDIMENTO_ID` | vazio | formato `...@g.us`; se vazio, o handoff só pausa e registra no log |
| `INCLUIR_LINK_WA` | `true` | inclui link `wa.me` da conversa no aviso do grupo |
| `MODO_TESTE` | `true` | em teste só responde números da allowlist |
| `ALLOWLIST` | vazio | números só com dígitos, com 55, separados por vírgula. **Em teste, esses números pulam o filtro de contato** |
| `CONTATOS_IGNORADOS` | vazio | **fallback** do filtro de contato (seção 2): números que o bot nunca atende, mantidos à mão |
| `OPENAI_MODEL` | `gpt-4o-mini` | trocar aqui |
| `TEMPERATURA` | `0.2` | |
| `DEBOUNCE_SEGUNDOS` | `5` | junta mensagens em sequência |
| `MEMORIA_TTL_HORAS` | `6` | sem mensagens por esse tempo = conversa encerrada por inatividade |
| `MEMORIA_MENSAGENS` | `10` | janela da memória por conversa |
| `PAUSA_HORAS` | `12` | quanto tempo o bot fica calado após handoff (renova a cada mensagem da atendente) |
| `MAX_IDADE_MSG_SEGUNDOS` | `300` | ignora mensagens mais velhas (replay após reconexão) |
| `TIMEZONE` | `America/Sao_Paulo` | |
| `DIAS_CALENDARIO` | `21` | tamanho do calendário injetado no prompt |

### 1.2 `INSTRUCOES` (editável pela esposa, sem tocar em modelo/credencial)

| Campo | Conteúdo |
|---|---|
| `PERSONA_E_REGRAS` | texto longo, rascunho no Anexo A |
| `FATOS_DO_PARQUE` | texto longo: endereço, regras de entrada, política de acompanhante, descontos, estacionamento. Placeholders `[PREENCHER]` |
| `AVISOS_DE_HOJE` | texto longo, vazio por padrão. Avisos pontuais (fechado hoje, horário especial). Vale mais que qualquer outra informação |
| `FERIADOS` | datas `YYYY-MM-DD` separadas por vírgula (valores iniciais abaixo) |
| `MSG_HANDOFF_CLIENTE` | "Vou chamar uma das nossas atendentes pra te ajudar com isso. Ela te responde por aqui em breve." |
| `MSG_MIDIA` | "Por enquanto eu só consigo ler mensagens de texto. Vou chamar uma atendente pra te ajudar." |

`FERIADOS` inicial: `2026-10-12,2026-11-02,2026-11-15,2026-11-20,2026-12-25,2027-01-01` (nacionais; adicionar feriados locais da cidade do parque).

### 1.3 O que o bot precisa saber sobre o parque (conteúdo mínimo de `FATOS_DO_PARQUE`)

Regra do dono: o bot não pode inventar nada que não exista no parque. Por isso `FATOS_DO_PARQUE` deve conter, no mínimo, os fatos abaixo (o texto final é escrito no valor da tabela, não aqui). Fora deste conteúdo e das tools de preço e horário, o bot não afirma nada sobre o parque (regra 0.5).

- **O que é:** playground indoor, dentro do Shopping Cidade Maringá.
- **Endereço:** Av. Tuiuti, 710 - Gleba Patrimônio, Maringá - PR, 87043-720.
- **Atrações** (site, "mais de 10 atrações"): Arena de Camas Elásticas, Guerreiro Ninja, Parede de Escalada, Desafio Radical, Pula-Pula, Salão de Festas, Bar e Petiscaria (há mais atrações no site que não aparecem na imagem; o bot só cita as listadas aqui).
- **Bar para os pais** que esperam os filhos brincarem: tem chopp e alguns petiscos. **Cardápio e preços do bar só no local:** se o cliente perguntar, o bot diz isso, não cita itens nem valores e **não** faz handoff por causa disso.
- **Salão de festas:** pode ser alugado para festas. Qualquer pedido de festa vai para atendente humana (regra 4 da persona, inalterada); o bot não informa preço nem detalha o pacote.
- **Preços e horários que aparecem na imagem do site são ignorados:** só valem os que vêm das tools `consultar_passaportes` e `consultar_horarios`.

![Detalhes do parque no Google (tipo de serviço, localização, endereço)](images/google-business-details.png)

Vinculante nesta imagem: nome do shopping e endereço. O telefone e o horário que aparecem nela não entram na spec nem em `FATOS_DO_PARQUE` (horário vem da tool).

![Página inicial do site do parque](images/site-landing-page.png)

Vinculante nesta imagem: a lista de atrações, o bar e petiscaria e o salão de festas como contexto do que existe no parque. **Não vinculante:** todos os preços e horários dela.

## 2. Bloco ENTRADA E FILTROS

- **2.1 WAHA Trigger:** usar **somente o evento `message.any`** (traz mensagens recebidas e enviadas). Não ligar `message` junto, senão duplica.
- **2.2 Filtros, nesta ordem (qualquer falha encerra a execução sem resposta):**
  1. `chatId` termina em `@g.us`, `@broadcast` ou `@newsletter` → ignorar (inclui o grupo de atendimento).
  2. `fromMe = true` → desviar para o bloco 3 (detecção de atendente).
  3. Mensagem mais velha que `MAX_IDADE_MSG_SEGUNDOS` → ignorar.
  4. `MODO_TESTE = true` e número fora da `ALLOWLIST` → ignorar.
  5. **Só número desconhecido** (detalhes abaixo): se o número está salvo na agenda do celular → ignorar.
- **2.3 Tipo da mensagem** (detectar pelo `hasMedia` e pelo tipo/mimetype do payload real):
  - **Texto** → segue o fluxo.
  - **Áudio/nota de voz, imagem, vídeo, documento, localização ou contato** → enviar `MSG_MIDIA` e ir ao handoff (bloco 7) com motivo "cliente enviou {tipo}" e resumo fixo "Cliente enviou {tipo}" (incluir a legenda, se houver). O agente não é chamado. O handoff acontece uma vez: com o chat pausado, o que vier depois fica em silêncio.
  - **Figurinha** → ignorar, sem resposta e sem handoff.
- Se `chatId` vier como `@lid`, o telefone real pode não estar no payload. Usar o campo que o WAHA fornecer (conferir no payload real); no pior caso, mostrar só o nome do contato no aviso do grupo e omitir o link.

### Filtro 5: o bot só atende quem não está na agenda

Regra do dono: família, amigos e fornecedores salvos no celular nunca ativam o bot; um cliente que o número nunca teve na agenda é atendido pelo bot.

- Consultar o contato pelo node nativo do WAHA e ler o campo `isMyContact`. `true` → ignorar, sem resposta e sem pausa.
- **Falhar fechado:** se a consulta der erro ou vier sem o campo, ignorar a mensagem e registrar no log. É melhor deixar de responder um cliente (a atendente vê no celular) do que responder o bot para um conhecido.
- **Validar no engine escolhido antes de qualquer coisa.** O `isMyContact` pode não vir preenchido em todos os engines do WAHA (e alguns exigem o store de contatos ligado). Testar com um número salvo e um não salvo. A escolha do engine depende desse teste.
- **Fallback se o campo não existir:** usar `CONTATOS_IGNORADOS` (lista manual no CONFIG). Se nem a operação de contato existir no plugin, avisar o dono.
- **Em `MODO_TESTE`**, números da `ALLOWLIST` pulam este filtro. Sem isso o dono, que está salvo no celular, nunca conseguiria testar.

## 3. Bloco PAUSA E ATENDENTE HUMANA

Estado no Redis, uma chave por chat: `pausa:{chatId}` com TTL = `PAUSA_HORAS`.

- **3.1 Detectar atendente:** mensagem com `fromMe = true` e `source` diferente de `api` foi digitada por uma pessoa no celular do parque → gravar `pausa:{chatId}` (renova o TTL) e encerrar. Assim a pausa dura enquanto a atendente estiver conversando e termina `PAUSA_HORAS` depois da última mensagem dela.
- **Validar o payload real antes de confiar no `source`.** Fallback se o campo não existir: ao enviar mensagem pelo bot, gravar o id retornado em `bot-msg:{id}` (TTL 120s); `fromMe` com id desconhecido = atendente. Mensagens do próprio bot nunca pausam.
- **3.2 Checar pausa (mensagens do cliente):** Redis Get em `pausa:{chatId}`; se existir, encerrar sem responder.

## 4. Bloco AGRUPAR MENSAGENS (debounce)

Cliente costuma mandar várias mensagens seguidas. Padrão com Redis (funciona com vários workers):

1. Push do texto em `buf:{chatId}` e Set de `ultima:{chatId}` = id da mensagem atual.
2. Send Seen e Start Typing (WAHA).
3. Wait `DEBOUNCE_SEGUNDOS`.
4. Redis Get `ultima:{chatId}`: se for diferente do id atual, encerrar (outra execução responde).
5. Se for igual: **checar de novo `pausa:{chatId}`** (o cliente pode ter mandado um áudio nesse intervalo e disparado o handoff); se estiver pausado, encerrar. Senão, ler a lista `buf:{chatId}`, apagar a chave e juntar os textos em um só.

## 5. Bloco CONVERSA (sessão) e CONTEXTO

### 5.1 Sessão da conversa

Uma "conversa" é um período contínuo de atendimento. Quando acaba, a próxima mensagem do cliente começa uma conversa nova (memória vazia, o bot se apresenta de novo).

- Redis `conv:{chatId}` guarda o `conversaId`. Em cada mensagem: Get; se não existir, criar um id novo; em ambos os casos, regravar com TTL = `MEMORIA_TTL_HORAS` (TTL deslizante).
- A memória do agente usa `sessionKey = {chatId}:{conversaId}`.
- **Encerrar a conversa = apagar `conv:{chatId}`.**

Uma conversa termina de três formas:

| Como termina | O que acontece |
|---|---|
| **Inatividade** | `conv` expira após `MEMORIA_TTL_HORAS` sem mensagens. Nada é enviado. |
| **Dúvidas resolvidas** | o cliente confirma que a dúvida foi resolvida (ver confirmação abaixo) e o agente devolve `status = resolvido`. Envia mensagem de finalização, apaga `conv`. **Sem pausa.** |
| **Precisa de humano** | o agente devolve `status = humano` (ou mídia/erro, ou o cliente diz que a dúvida **não** foi resolvida). O bot **para de responder** (pausa), avisa o grupo (bloco 7) e apaga `conv`. |

**Confirmação de encerramento (regra do dono, 2026-10-13).** No fim do atendimento o bot **pergunta** se a dúvida do cliente foi resolvida:

1. Quando o bot já respondeu o que foi perguntado e não há pergunta pendente, a resposta termina com a pergunta de confirmação. O `status` dessa resposta é `continua`.
2. Cliente confirma que resolveu (sim, "era só isso", "obrigado" em resposta à pergunta) → `status = resolvido`, mensagem de finalização, `conv` apagada, **sem pausa e sem aviso no grupo**.
3. Cliente diz que **não** resolveu → `status = humano` (handoff do bloco 7, com pausa).
4. Cliente responde com outra pergunta em vez de sim/não → o bot responde normalmente e volta a perguntar no fim.
5. Se o próprio cliente encerra de forma explícita antes de ser perguntado ("era só isso, obrigado"), isso conta como confirmação: vai direto para `resolvido`, sem perguntar de novo.
6. O bot nunca devolve `resolvido` na mesma resposta em que informa preço ou horário.

### 5.2 Contexto (Code node, sem chamada de API)

Montar o texto do contexto, calculado em `TIMEZONE`:

- **Agora:** dia da semana por extenso, data e hora.
- **Calendário** de hoje até `DIAS_CALENDARIO` dias, uma linha por dia: `2026-10-12 segunda-feira | FERIADO | preço: sexta-a-domingo/feriado (weekendPrice) | horário: domingos e feriados (sundays_holidays)`.

Regras do calendário (determinísticas, o modelo não calcula data):

```
feriado(d)      = d está em FERIADOS
tierPreco(d)    = (feriado(d) ou dia da semana em [sexta, sábado, domingo]) ? weekendPrice : weekdayPrice   // seg–qui = weekdayPrice
tierHorario(d)  = (feriado(d) ou domingo) ? sundays_holidays : weekdays                                      // seg–sáb = weekdays
```

Depois montar o `system message` = `PERSONA_E_REGRAS` + `FATOS_DO_PARQUE` + `AVISOS_DE_HOJE` + contexto acima.

Caso de teste do dia da spec: 12/10/2026 é segunda e feriado (Dia das Crianças): passaporte usa `weekendPrice` e horário usa `sundays_holidays`.

## 6. Bloco AGENTE

- **AI Agent** + **OpenAI Chat Model** (modelo e temperatura vindos do CONFIG) + **Redis Chat Memory** (`sessionKey = {chatId}:{conversaId}`, janela = `MEMORIA_MENSAGENS`).
- **Structured Output Parser** com este formato:

```json
{
  "resposta": "texto para o cliente",
  "status": "continua",
  "motivo": "",
  "resumo": ["linha 1", "linha 2", "linha 3"]
}
```

`status` aceita só três valores:

- `continua`: responder normalmente; a conversa segue.
- `resolvido`: o cliente confirmou que a dúvida foi resolvida (seção 5.1); `resposta` é a mensagem de finalização, curta.
- `humano`: precisa de atendente; `resposta` avisa o cliente, `motivo` é curto e `resumo` tem até 3 linhas (o que o cliente perguntou e onde parou).

- **Tools (HTTP Request Tool, cada uma com `Authorization: Bearer {{ $('CONFIG').item.json.SITE_API_TOKEN }}`):**
  - `consultar_passaportes`: `GET {API_BASE_URL}{PATH_PRECOS}?type=passaportes&perPage=100`
  - `consultar_horarios`: `GET {API_BASE_URL}{PATH_HORARIOS}?perPage=100`
- **Não criar tool de preço de festa na v1** (ver seção de decisões).
- Se a versão instalada do n8n permitir Code Tool com chamada HTTP, é melhor formatar a resposta na tool (R$ 45,00, "10h às 22h") e já devolver só o preço do dia pedido. Se não, usar HTTP Request Tool e deixar a formatação no prompt.
- Erro/timeout/vazio em qualquer tool vira `status = humano`. Em caso de falha do próprio agente, usar a saída de erro do node e ir ao handoff com motivo "falha técnica".

### Formato real da API (conforme OpenAPI)

Resposta: `{ "data": [...], "pagination": { page, perPage, total, totalPages } }`. Erros: `{ "error": "..." }` (401 = token inválido).

**Preços** (`/content/prices`): cada item tem `id`, `key`, `name`, `weekdayPrice` (string, ex. `"45.00"`), `weekendPrice` e `type` (`salao` ou `passaportes`). Cada passaporte aparece em **duas linhas**: `id = "<passaporte>:child"` e `"<passaporte>:companion"`, com `key` terminando em `_child` / `_companion`.

- Passaportes (admin): 30 min, 1 h, 2 h, 3 h. `weekdayPrice` = segunda a quinta; `weekendPrice` = sexta a domingo e feriados. **Confirmar com uma resposta real** (30 minutos, criança: `45.00` e `50.00`).
- A duração só aparece no `name`, não há campo de duração. Conferir no JSON real como os nomes das linhas criança/acompanhante vêm; se forem iguais, distinguir pelo `key`/`id`.

**Horários** (`/content/hours`): `id`, `key`, `label`, `opening`, `close` (hora cheia). Chaves: `weekdays` (segunda a sábado, 10 às 22) e `sundays_holidays` (domingos e feriados, 12 às 20). **Decidir por `key`, nunca pelo `label`.**

## 7. Bloco RESPOSTA, ENCERRAMENTO E HANDOFF

Depois do agente, desviar por `status`:

- **`continua`:** Stop Typing, Send Text com `resposta`. Registrar o id enviado em `bot-msg:{id}` (fallback do bloco 3).
- **`resolvido`:** Stop Typing, Send Text com `resposta` (mensagem de finalização), apagar `conv:{chatId}`. Sem pausa (o bot não entra em standby), sem aviso no grupo.
- **`humano`** (também vindo do bloco 2.3 e dos erros), nesta ordem:
  1. Send Text ao cliente com `resposta` (ou `MSG_HANDOFF_CLIENTE`).
  2. Redis Set `pausa:{chatId}` com TTL `PAUSA_HORAS`: **o bot para de responder esse chat.**
  3. Apagar `conv:{chatId}` (encerra a conversa do bot).
  4. Send Text no `GRUPO_ATENDIMENTO_ID` (se vazio, pular e registrar no log):

```
Atendimento humano necessário
Cliente: {nome do contato} — +55 11 99999-9999
Conversa: https://wa.me/5511999999999
Motivo: {motivo}
Resumo:
• {linha 1}
• {linha 2}
• {linha 3}
Última mensagem: "{texto}"
O bot parou de responder este chat por {PAUSA_HORAS}h (renova a cada mensagem da atendente).
```

Formatar o telefone a partir do `chatId` (remover o sufixo, aplicar `+55 DD NNNNN-NNNN`; no link, só dígitos). A linha `Conversa:` só entra se `INCLUIR_LINK_WA = true` e o telefone real estiver disponível. O link `wa.me` abre a conversa **no WhatsApp de quem clicar**: serve para a atendente que usa o aparelho do número do parque; se ela clicar no celular pessoal, a conversa começará pelo número pessoal dela.

## 8. Decisões assumidas (editáveis, confirmar quando possível)

| Item | Assumido na v1 | O que destrava a mudança |
|---|---|---|
| Quem o bot atende | só número fora da agenda, falhando fechado se a consulta falhar | teste do `isMyContact` no engine escolhido |
| Preço de festa | Bot **não informa**; vai para handoff | Dono confirmar a unidade dos valores do salão (total ou por criança) e o que "Passaporte Avulso (festa)" e "Pacote de 10" compõem. Aí ligar `type=salao` como tool |
| Reserva/data/disponibilidade | Sempre handoff | v2 com Google Calendar |
| Áudio, imagem, vídeo | Aviso + handoff | v2: transcrever o áudio (baixar a mídia pelo node do WAHA e transcrever com a OpenAI) e tratar como texto. Imagem e vídeo continuam com humano |
| Fim de handoff | Bot volta quando a pausa expira, em conversa nova | v2: comando para reativar |
| Link `wa.me` no grupo | ligado | desligar em `INCLUIR_LINK_WA` se não ajudar |
| Modelo | `gpt-4o-mini` | trocar no CONFIG |

## 9. Testes de aceite

1. "Quanto é a entrada?" sem data: o bot pergunta o dia da visita (ou lista os dois preços) e usa o tier certo.
2. Hoje (12/10, feriado): passaporte em `weekendPrice`; horário 12h às 20h.
3. "Quanto é na terça?" usa `weekdayPrice`. "E no sábado?" usa `weekendPrice`.
4. "Vocês estão abertos agora?" compara a hora de Brasília com a faixa do dia.
5. "Quero fazer uma festa" → `humano`, sem informar preço de festa.
6. Áudio, imagem, vídeo ou documento → `MSG_MIDIA` + handoff uma vez só; mensagens seguintes durante a pausa são ignoradas. Figurinha → ignorada, sem resposta. Texto seguido de áudio em menos de 5 s → só o handoff, sem resposta do agente.
7. **Número desconhecido** → bot atende. **Número salvo na agenda** → bot ignora (sem resposta, sem pausa, sem aviso no grupo).
8. Em `MODO_TESTE`, número da allowlist salvo na agenda → bot atende (pula o filtro de contato).
9. Consulta de contato falha → mensagem ignorada e registrada no log.
10. Cliente diz "era só isso, obrigado" → `resolvido`: mensagem de finalização, `conv` apagada, **sem pausa**; mensagem nova horas depois → o bot se apresenta de novo.
18. Bot informa um preço ou horário → a resposta termina perguntando se a dúvida foi resolvida, com `status = continua` (nunca `resolvido` nessa mesma resposta).
19. Após a pergunta de confirmação, cliente responde "sim, resolvido" → `resolvido`: mensagem de finalização, `conv` apagada, **sem pausa e sem aviso no grupo**; nova mensagem logo em seguida é atendida pelo bot em conversa nova.
20. Após a pergunta de confirmação, cliente responde "não" ou "não resolveu" → `humano`: handoff do bloco 7, pausa em `pausa:{chatId}` e aviso no grupo.
21. Após a pergunta de confirmação, cliente faz outra pergunta → o bot responde e volta a perguntar no fim; sem handoff e sem encerrar.
22. "O que tem no parque?" → o bot cita só as atrações de `FATOS_DO_PARQUE` (seção 1.3), sem inventar outras e sem preço/horário que não venha das tools.
23. "Tem bar? Qual o cardápio e os preços?" → o bot confirma que há bar para os pais, com chopp e alguns petiscos, diz que cardápio e preços só no local, sem citar itens ou valores e **sem handoff**.
24. "Posso alugar o salão pra uma festa?" → o bot confirma que o salão pode ser alugado e vai para `humano`, sem informar preço de festa.
25. "Onde fica o parque?" → o bot responde que é um playground indoor no Shopping Cidade Maringá, com o endereço da seção 1.3.
11. Silêncio por `MEMORIA_TTL_HORAS` → a próxima mensagem inicia conversa nova.
12. Handoff → aviso no grupo com nome, link e resumo; o bot para de responder esse chat; quando a pausa expira, volta em conversa nova.
13. Atendente digita no celular → chat pausa; mensagem do bot via API **não** pausa.
14. Três mensagens em até 5 s → uma resposta só.
15. Token errado no CONFIG (401) ou API fora do ar → `humano`, nenhum preço inventado.
16. Mensagem no grupo de atendimento → ignorada. Número fora da allowlist em `MODO_TESTE` → ignorado.
17. Mensagem antiga (replay) → ignorada.

## 10. Infra (para o deploy, não faz parte do workflow)

- n8n com `GENERIC_TIMEZONE=America/Sao_Paulo`.
- WAHA: **definir o engine depois do teste do `isMyContact`** (seção 2). NOWEB/GOWS consomem menos RAM que o WEBJS, que sobe Chromium. Volume persistente na sessão, e a mesma sessão configurada em `WAHA_SESSION`.
- Guardar `N8N_ENCRYPTION_KEY` e agendar backup do Postgres.

## 11. Desvios da implementação (estado real em 2026-10-13)

Notas `Deviation:` pedidas pelo dono. O texto das seções 0 a 10 acima registra a intenção original; onde houver conflito, vale esta seção e o código (`workflows/chatbot-waha-divercity*.json`).

Deviation: **estrutura (seção 0.1 e 0.4).** O fluxo deixou de ser um workflow único. São 5 workflows, todos com o prefixo `[chatbot] ` no nome do n8n: o principal `[chatbot] Divercity` (gatilho WAHA, `CONFIG`, `INSTRUCOES` e uma chamada por etapa) e 4 subworkflows chamados com Execute Workflow: `Filtros` (blocos 2 e 3), `Agrupar mensagens` (bloco 4), `Agente` (blocos 5 e 6) e `Resposta e handoff` (bloco 7). `CONFIG` e `INSTRUCOES` existem só no principal e são passados em cada chamada. Os comentários (sticky notes) dos blocos foram removidos pelo dono ao reorganizar os nodes. Arquivos: `chatbot-waha-divercity.json`, `-filters`, `-debounce`, `-agent`, `-reply`. Motivo: o fluxo único ficou confuso de manter.

Deviation: **CONFIG e INSTRUCOES em Data Tables (seção 1).** Os dois nodes Set foram trocados por nodes Data Table que mantêm os nomes `CONFIG` e `INSTRUCOES` (as expressões `$('CONFIG').first().json.X` não mudaram). Os valores ficam em duas tabelas do n8n, uma linha cada: `chatbot_divercity_config` (colunas tipadas, uma por chave da seção 1.1, exceto `SITE_API_TOKEN`) e `chatbot_divercity_instrucoes` (as seis chaves da seção 1.2). O dono e a esposa editam pela aba **Data tables**; importar workflow não sobrescreve valores. O workflow `[chatbot] Divercity - Instalar tabelas` (`chatbot-waha-divercity-install.json`) cria as tabelas e a linha padrão só se não existirem e guarda os valores padrão versionados; ele precisa ser executado uma vez pelo editor do n8n (o CLI `n8n execute` não carrega o módulo de Data Tables). Se a tabela não existe, o `CONFIG` falha e vai para o workflow de erro; se existe sem linha, o fluxo termina sem enviar nada.

Deviation: **token do site (seções 1.1 e 6).** `SITE_API_TOKEN` deixou de ser campo do `CONFIG`: é a credencial `Site API token` do n8n (tipo Header Auth, `Authorization: Bearer <token>`), usada pelas duas ferramentas HTTP. O `scripts/setup.sh` cria a credencial a partir de `SITE_API_TOKEN` do `.env` (ou do placeholder `COLE_O_TOKEN_AQUI`); para trocar o token, edite a credencial no n8n, sem mexer em workflow.

Deviation: **filtro 5 (seção 2).** O sinal "número salvo na agenda" é o campo `name` do contato não vazio, consultado em `<telefone>@c.us`, e não `isMyContact` (o engine NOWEB não preenche esse campo). O telefone vem de `_data.key.remoteJidAlt`; sem telefone, ou com consulta inválida, a mensagem é ignorada e registrada (falha fechada). Nodes extras: `Tem telefone?` e `Consulta válida?`. Consulta pelo id `@lid` não serve, porque devolve `name` vazio para contato salvo.

Deviation: **identificação do chat (seção 2.1).** `chatId = (fromMe && to) ? to : from`, porque conversas privadas chegam como `<id>@lid` com `to = null`. `pausa:`, `buf:`, `ultima:`, `conv:` usam esse `chatId`.

Deviation: **chaves e limpeza (seções 3, 4, 7).** Foi acrescentada a chave `entrega:{idMensagem}` (deduplicação de entrega do webhook). A chave `bot-msg:{id}` é gravada em **todo** envio do bot (`continua`, `resolvido` e handoff), com o último trecho depois de `_` do id enviado, e não só em `continua`. O handoff também apaga `buf:{chatId}`.

Deviation: **mídia (seção 2.3).** O cliente que manda áudio, imagem, vídeo, documento, localização ou contato recebe só `MSG_MIDIA` (uma mensagem), sem `MSG_HANDOFF_CLIENTE`, e um único handoff.

Deviation: **agente e ferramentas (seção 6).** As ferramentas são o node `HTTP Request Tool` (`n8n-nodes-base.httpRequestTool` 4.5) com os nomes `consultar_passaportes` e `consultar_horarios`, porque o agente 3.1 do n8n 2.41.7 não executa `toolHttpRequest` 1.1. Falhas HTTP (401, 5xx, vazio) voltam ao modelo como dado e a regra 3 da persona manda para `humano`. O Structured Output Parser foi removido (falhava com o `gpt-4o-mini`): o modelo responde JSON no texto e o node `6.1 Interpretar resposta` lê a resposta. Ele aceita JSON puro, JSON com cercas de código, o wrapper `{"output": {...}}` ou JSON com texto em volta; texto puro vira `resposta` com status `continua`; vazio, status inválido ou JSON quebrado vai para o handoff (`falha técnica`).

Deviation: **persona (seção 1.2 e Anexo A).** A pedido do dono, o Dry conversa: responde cumprimentos e mensagens vagas com perguntas curtas e só usa `humano` quando não sabe responder ou nos casos da regra 4 (festa, orçamento, reserva, data, disponibilidade, pagamento, reclamação, pedir pessoa). `resolvido` só quando o cliente encerra de forma explícita, nunca logo depois de informar preço ou horário. O texto vigente é o valor de `INSTRUCOES.PERSONA_E_REGRAS` no workflow principal; o Anexo A abaixo é o rascunho original.

Deviation: **valores e convenções.** `WAHA_SESSION = "Default"` (D maiúsculo, nome real da sessão). Expressões usam `.first()` em vez de `.item`. Identificadores, nomes de nodes e chaves em português por decisão do dono (exceção à regra de inglês do `CLAUDE.md`). Todos os workflows têm `errorWorkflow` `FF0x666oa1bfHLDI`, então uma falha dentro de um subworkflow pode gerar dois alertas (no sub e no principal). O hook global do WAHA (`WHATSAPP_HOOK_URL`, evento `message.any`) aponta para o gatilho do workflow principal.

Deviation: **teste de aceite (seção 9).** Confirmados ao vivo em 2026-10-13, com número de teste: 2 (feriado 12/10 → `weekendPrice`, 12h às 20h) e 13 (mensagem do próprio bot não pausa). O restante da lista está no checklist da fase 12 do `plan.md`.

Pendente de implementação (mudança de spec de 2026-10-13, ainda não refletida no código): (a) `FATOS_DO_PARQUE` deve passar a ter o conteúdo da seção 1.3; (b) `PERSONA_E_REGRAS` deve incluir a pergunta de confirmação de encerramento da seção 5.1 (a regra atual de `resolvido` só espera o cliente encerrar sozinho); (c) a mensagem de finalização e a pergunta de confirmação são redigidas pelo modelo seguindo a persona, não há campo novo em `INSTRUCOES`.

Decisões em aberto:

- **OD1 — regras de acompanhante e descontos do site.** A imagem do site traz regras que não são preço nem horário e, portanto, podem ser úteis ao bot, mas o texto da imagem está pequeno. Leitura provisória: crianças de 1 a 4 anos devem ir com responsável maior de 18 anos, e o acompanhante não paga (1 por criança); PNE tem acompanhante isento (1 por pessoa); crianças a partir de 5 anos não precisam de acompanhante, e quem entrar na área de brinquedos paga a taxa de acompanhante do tempo escolhido; criança de 0 a 1 ano que use os brinquedos e PNE têm 50% de desconto; a partir de 1 ano paga o valor integral. · Opções: (a) dono confirma o texto e ele entra em `FATOS_DO_PARQUE`; (b) bot não fala de acompanhante/desconto e encaminha ao humano · Recomendação: (a), com o dono revisando a leitura acima, porque descontos são regra de valor e o bot não pode errá-los. Até lá, fica valendo (b).
- **OD2 — itens do bar.** O dono informou chopp e alguns petiscos; a imagem do site também cita bebidas e café. · Opções: (a) só chopp e petiscos · (b) bebidas, chopp, petiscos e café · Recomendação: (a) até o dono confirmar; o bot diz "cardápio só no local".

## Anexo A — rascunho de `PERSONA_E_REGRAS`

```
Você é o Dry, assistente virtual do Divercity Park, atendendo clientes pelo WhatsApp.
Fale em português do Brasil, de forma simpática, curta e direta (1 a 4 linhas por mensagem,
no máximo um emoji). Se não houver mensagens anteriores na memória, apresente-se como
assistente virtual.

O QUE VOCÊ FAZ
- Informar preço de passaporte (entrada), horário de funcionamento e o que estiver em
  "FATOS DO PARQUE".
- Todo o resto você encaminha para a atendente (status "humano").

REGRAS
1. Nunca invente preço, horário, regra ou desconto. Use só o que vier das ferramentas,
   de "FATOS DO PARQUE" ou de "AVISOS DE HOJE". Se o aviso contradiz outra informação, o aviso vale.
2. Preço e horário: sempre consulte a ferramenta antes de responder. Não reaproveite valores
   de mensagens anteriores.
3. Se a ferramenta falhar, vier vazia ou você não tiver certeza: status "humano".
4. Festa, aniversário, orçamento, reserva do salão, data, disponibilidade, pagamento,
   reclamação ou pedido para falar com uma pessoa: status "humano". Não informe preço de festa.
5. Nunca prometa nada em nome do parque (desconto, reserva, exceção).

PASSAPORTE
- Tem preço de criança e de acompanhante, por duração (30 min, 1 h, 2 h, 3 h).
- O preço depende do dia: use o CALENDÁRIO abaixo para saber qual preço vale na data.
  Se o cliente não disse o dia da visita, pergunte antes de informar um valor.
- Escreva valores como R$ 45,00. Informe só as durações que o cliente pediu; se não pediu
  nenhuma, ofereça as opções.

HORÁRIO
- Use a faixa do dia indicada no CALENDÁRIO e o horário da ferramenta.
- Para "estão abertos agora?", compare a hora atual (horário de Brasília) com a faixa de hoje.

STATUS (sempre no JSON de saída)
- "continua": você respondeu e a conversa segue.
- "resolvido": o cliente disse que era só isso, agradeceu ou as dúvidas foram atendidas.
  Despeça-se em uma linha ("Qualquer dúvida é só chamar!").
- "humano": precisa de atendente. "resposta" avisa o cliente que uma atendente vai
  continuar a conversa; "motivo" é curto; "resumo" tem até 3 linhas com o que o cliente
  perguntou e onde parou.
```