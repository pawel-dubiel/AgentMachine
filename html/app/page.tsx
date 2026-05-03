const principles = [
  "Explicit run specs",
  "Scoped tool authority",
  "Agentic workflows",
  "JSONL observability"
];

const capabilities = [
  {
    label: "Runtime",
    value: "Elixir / OTP",
    text: "Supervised runs, isolated agent tasks, retries, finalizers, usage totals, and event collection."
  },
  {
    label: "Tools",
    value: "deny by default",
    text: "Local files, code edits, commands, browser MCP, and skills only appear when the run config allows them."
  },
  {
    label: "Clients",
    value: "CLI + Go TUI",
    text: "Scriptable Mix tasks and a thin terminal UI over the same runtime boundary."
  }
];

const events = [
  "workflow_routed",
  "agent_started",
  "tool_call_started",
  "tool_call_finished",
  "run_completed"
];

export default function Home() {
  return (
    <main>
      <section className="hero" aria-labelledby="hero-title">
        <nav className="nav" aria-label="Primary">
          <a className="brand" href="#top" aria-label="AgentMachine home">
            <span className="brandMark" aria-hidden="true" />
            AgentMachine
          </a>
          <div className="navLinks">
            <a href="#runtime">Runtime</a>
            <a href="#tools">Tools</a>
            <a href="#install">Install</a>
          </div>
        </nav>

        <div className="heroGrid" id="top">
          <div className="heroCopy">
            <p className="eyebrow">Elixir agent runtime</p>
            <h1 id="hero-title">
              Controlled AI workflows for real project work.
            </h1>
            <p className="lead">
              Build agents that can inspect, edit, browse, run checks, and
              explain every step through explicit permissions and auditable
              execution.
            </p>

            <div className="actions" aria-label="Primary actions">
              <a className="button primary" href="#install">
                Start locally
              </a>
              <a className="button secondary" href="#runtime">
                See runtime
              </a>
            </div>

            <ul className="principles" aria-label="Core principles">
              {principles.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ul>
          </div>

          <div className="runtimePanel" aria-label="AgentMachine runtime trace">
            <div className="panelTop">
              <span>run-9f2a</span>
              <span>agentic</span>
            </div>
            <div className="trace">
              {events.map((event, index) => (
                <div className="traceRow" key={event}>
                  <span className="traceIndex">{String(index + 1).padStart(2, "0")}</span>
                  <span>{event}</span>
                  <span className="traceStatus">ok</span>
                </div>
              ))}
            </div>
            <div className="panelFoot">
              <span>tools: code-edit, mcp</span>
              <span>root: explicit</span>
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="runtime" aria-labelledby="runtime-title">
        <div className="sectionHeader">
          <p className="eyebrow">Runtime boundary</p>
          <h2 id="runtime-title">Small surface, strict contracts.</h2>
        </div>
        <div className="capabilityGrid">
          {capabilities.map((item) => (
            <article className="capability" key={item.label}>
              <p>{item.label}</p>
              <h3>{item.value}</h3>
              <span>{item.text}</span>
            </article>
          ))}
        </div>
      </section>

      <section className="split section" id="tools" aria-labelledby="tools-title">
        <div>
          <p className="eyebrow">Tool policy</p>
          <h2 id="tools-title">Capabilities are not defaults.</h2>
        </div>
        <div className="copyBlock">
          <p>
            Models receive only the tools selected for the current run. The
            runtime validates roots, command budgets, MCP schemas, approval
            risk, and exact test-command allowlists before anything touches the
            project.
          </p>
          <p>
            Missing state fails early. Side effects are only reported when tool
            results prove them.
          </p>
        </div>
      </section>

      <section className="install" id="install" aria-labelledby="install-title">
        <div>
          <p className="eyebrow">Local first</p>
          <h2 id="install-title">Run it from the terminal.</h2>
        </div>
        <pre aria-label="Install commands">
          <code>{`make deps
make run-echo TASK="Summarize this project"
make run`}</code>
        </pre>
      </section>
    </main>
  );
}
