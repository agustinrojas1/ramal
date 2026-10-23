defmodule RamalLive.Style do
  @moduledoc false
  # The inspector's CSS, inline: no Tailwind and no asset pipeline, so the page adds nothing to the host's build.
  #
  # The identity is the logo's: slate for the base line, copper only for branches. The dark theme uses the dark logo's
  # cream and light amber. Headings ask for Barlow Condensed and data for IBM Plex Mono; the host's page loads them
  # (README has the link tag) and the stacks fall back to what the system has, because a library must not make the
  # reader's browser call a font CDN on its own.

  @light """
  --rl-bg: #f6f4ee;
  --rl-card: #ffffff;
  --rl-ink: #243044;
  --rl-muted: #5b6678;
  --rl-line: #d9d5c9;
  --rl-base: #243044;
  --rl-branch: #d98324;
  --rl-add: #1d6b45;
  --rl-add-bg: #e3f1e8;
  --rl-del: #a8322a;
  --rl-del-bg: #f8e4e1;
  --rl-button: #243044;
  --rl-button-ink: #f6f4ee;
  --rl-danger: #a8322a;
  --rl-danger-ink: #ffffff;
  """

  @dark """
  --rl-bg: #12161c;
  --rl-card: #1a2029;
  --rl-ink: #e6e1d6;
  --rl-muted: #9aa3b2;
  --rl-line: #2c3542;
  --rl-base: #e6e1d6;
  --rl-branch: #f0a04b;
  --rl-add: #7fd1a1;
  --rl-add-bg: #17301f;
  --rl-del: #f09a92;
  --rl-del-bg: #3a1c1a;
  --rl-button: #e6e1d6;
  --rl-button-ink: #12161c;
  --rl-danger: #e06a5f;
  --rl-danger-ink: #12161c;
  """

  @doc "The stylesheet, scoped to the `.ramal` root so that it cannot leak into the host's page."
  @spec css() :: String.t()
  def css do
    """
    .ramal { #{@light} }
    @media (prefers-color-scheme: dark) { .ramal:not([data-theme="light"]) { #{@dark} } }
    .ramal[data-theme="dark"] { #{@dark} }
    #{rules()}
    """
  end

  defp rules do
    """
    .ramal { box-sizing: border-box; background: var(--rl-bg); color: var(--rl-ink); padding: 1.25rem; min-height: 100vh;
      font-family: inherit; line-height: 1.4; }
    .ramal *, .ramal *::before, .ramal *::after { box-sizing: inherit; }
    .ramal h1, .ramal h2 { font-family: "Barlow Condensed", "Arial Narrow", "Roboto Condensed", sans-serif-condensed, sans-serif;
      font-weight: 600; letter-spacing: .02em; margin: 0; }
    .ramal code, .ramal .rl-data { font-family: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .8125rem; }
    .ramal button { font: inherit; cursor: pointer; }
    .ramal button:focus-visible { outline: 2px solid var(--rl-ink); outline-offset: 2px; }
    .rl-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: .5rem 1rem; }
    .rl-head h1 { font-size: 1.75rem; text-transform: uppercase; }
    .rl-domain { color: var(--rl-muted); }
    .rl-tools { margin-left: auto; display: flex; gap: .5rem; }
    .rl-baseline { height: 6px; border-radius: 3px; background: var(--rl-base); margin: .75rem 0 1.25rem; }
    .rl-banner { border: 1px solid var(--rl-line); border-left: 4px solid var(--rl-base); background: var(--rl-card);
      padding: .5rem .75rem; margin-bottom: 1rem; display: flex; gap: .75rem; align-items: baseline; }
    .rl-banner[data-kind="error"] { border-left-color: var(--rl-danger); }
    .rl-banner > span { flex: 1; }
    .rl-board { display: flex; gap: 1rem; align-items: flex-start; overflow-x: auto; padding-bottom: 1rem; }
    .rl-empty-board { color: var(--rl-muted); }
    .rl-col { flex: 0 0 22rem; max-width: 22rem; background: var(--rl-card); border: 1px solid var(--rl-line);
      border-top: 4px solid var(--rl-branch); border-radius: 6px; padding: .75rem; }
    .rl-col[data-status="proposed"] { border-top-style: dashed; }
    .rl-col-head { display: flex; gap: .5rem; align-items: center; }
    .rl-col-head h2 { font-size: 1.25rem; flex: 1; overflow-wrap: anywhere; }
    .rl-dot { width: .75rem; height: .75rem; border-radius: 50%; background: var(--rl-branch); flex: none; }
    .rl-status { font-family: "Barlow Condensed", "Arial Narrow", sans-serif-condensed, sans-serif; text-transform: uppercase;
      letter-spacing: .06em; font-size: .8125rem; border: 1px solid var(--rl-line); border-radius: 3px; padding: 0 .4rem; }
    .rl-meta { display: grid; grid-template-columns: auto 1fr; gap: .1rem .75rem; margin: .5rem 0; color: var(--rl-muted);
      font-size: .8125rem; }
    .rl-meta dt { margin: 0; }
    .rl-meta dd { margin: 0; color: var(--rl-ink); }
    .rl-proposal { border-left: 3px solid var(--rl-line); padding-left: .5rem; margin: .5rem 0; font-size: .875rem; }
    .rl-changes { list-style: none; margin: .5rem 0; padding: 0; display: grid; gap: .5rem; }
    .rl-change { border: 1px solid var(--rl-line); border-radius: 4px; overflow: hidden; }
    .rl-change-head { display: flex; gap: .5rem; align-items: baseline; padding: .25rem .5rem; background: var(--rl-bg); }
    .rl-kind { font-family: "Barlow Condensed", "Arial Narrow", sans-serif-condensed, sans-serif; text-transform: uppercase;
      letter-spacing: .06em; font-size: .75rem; }
    .rl-kind[data-kind="created"] { color: var(--rl-add); }
    .rl-kind[data-kind="deleted"] { color: var(--rl-del); }
    .rl-rows { width: 100%; border-collapse: collapse; table-layout: fixed; }
    .rl-rows th, .rl-rows td { text-align: left; font-weight: 400; padding: .15rem .5rem; vertical-align: top;
      overflow-wrap: anywhere; }
    .rl-rows th { color: var(--rl-muted); width: 28%; }
    .rl-rows td.rl-id, .rl-change-head .rl-id { white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      overflow-wrap: normal; }
    .rl-change-head .rl-id { flex: 1 1 0; min-width: 0; }
    .rl-before { background: var(--rl-del-bg); color: var(--rl-del); }
    .rl-after { background: var(--rl-add-bg); color: var(--rl-add); }
    .rl-before:empty, .rl-after:empty { background: none; }
    .rl-none { color: var(--rl-muted); font-size: .875rem; margin: .5rem 0; }
    .rl-notice { margin: .5rem 0; padding: .4rem .5rem; border-left: 4px solid var(--rl-base); background: var(--rl-bg);
      font-size: .875rem; overflow-wrap: anywhere; }
    .rl-notice[data-kind="error"] { border-left-color: var(--rl-danger); }
    .rl-actions { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin-top: .75rem; }
    .rl-confirm { flex: 1 0 100%; font-size: .875rem; }
    .rl-btn { background: transparent; color: var(--rl-ink); border: 1px solid var(--rl-ink); border-radius: 4px;
      padding: .25rem .75rem; }
    .rl-btn:hover { background: var(--rl-bg); }
    .rl-btn[data-variant="primary"] { background: var(--rl-button); color: var(--rl-button-ink); }
    .rl-btn[data-variant="danger"] { background: var(--rl-danger); border-color: var(--rl-danger); color: var(--rl-danger-ink); }
    .rl-btn[disabled] { opacity: .5; cursor: progress; }
    """
  end
end
