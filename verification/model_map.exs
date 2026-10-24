# Which code each step of each formal model stands for, and why no model reads the rest of lib/ (ADR 0050).
#
# test/ramal/model_map_test.exs reads this file with test/support/model_map.ex. It fails when
#
#   * a function named here, or cited in a .tla comment, is gone or has another arity;
#   * a step named here is not defined in its model;
#   * a file under lib/ is neither the home of a modelled function nor listed in `not_modelled`;
#   * the code of a step changed: the hash in model_map.stamps no longer matches (see its header).
#
# `code` lists `Module.function/arity`, a `@callback` of a behaviour included. A step may share functions with others.
# A step with `code: []` models something outside the library (the node restarting, a caller dying, another writer).
#
# Adding a step to a model: add it here. Adding a module under lib/: put it in `not_modelled` with the reason, or
# make a step of a model cite it.
alias_server = "Ramal.Branch.Server"

step = fn model, step, code, why -> %{model: model, step: step, code: code, why: why} end
ramal = "tla/Ramal.tla"
nested = "tla/Nested.tla"
cluster = "tla/Cluster.tla"
bend = "bend/model.bend"

s = fn name -> "#{alias_server}.#{name}" end

# A storage callback, and the two backends that implement it.
st = fn name -> ["Ramal.Storage.#{name}", "Ramal.Storage.ETS.#{name}", "Ramal.Storage.Postgres.#{name}"] end

%{
  steps: [
    # -- tla/Ramal.tla: the life of branches across processes ------------------------------------------------------
    step.(ramal, "Start", [s.("ensure_started/2"), s.("init/1"), s.("recover/2"), s.("apply_deltas/2"),
                           "Ramal.Branch.apply_delta/3", "Ramal.Supervisor.too_large?/1"] ++ st.("fetch/2") ++ st.("writes_after/2"),
          "a call for a branch with no process loads it from storage, with the write log applied"),
    step.(ramal, "Idle", [s.("handle_info/2"), s.("timeout/1"), s.("stopped/2"), s.("terminate/2"), s.("persist/2")] ++ st.("put/2"),
          "an idle branch persists and stops, never while claimed or with an action running"),
    step.(ramal, "Kill", [s.("heap_limit/1")], "max_heap_size kills the process without terminate/2"),
    step.(ramal, "Watcher", [s.("watch/1"), "Ramal.Supervisor.mark_too_large/1"],
          "the watcher marks a killed process so it is not reloaded from storage"),
    step.(ramal, "Down", [s.("handle_info/2"), s.("take_back/2"), s.("drop_running/2"), s.("serve_waiting/1")],
          "a calling process that dies mid-action has all its writes taken back"),
    step.(ramal, "NodeCrash", [], "the node restarts: the VM and its ETS tables, not library code"),
    step.(ramal, "External", [], "someone writes the base outside any branch"),
    step.(ramal, "Read", ["Ramal.Branch.put_fingerprints/2", s.("fingerprints/2")],
          "a read fingerprints the base rows it returns"),
    step.(ramal, "Write", ["Ramal.Capture.write/4", s.("capture/3"), s.("hold/3"), s.("busy?/3"), s.("row_busy/2"),
                           "Ramal.Branch.put_write/6", s.("handle_call/3")],
          "an action's first write is held under its calling process; a row another running action holds is refused"),
    step.(ramal, "WriteMore", ["Ramal.Capture.write/4", s.("capture/3"), s.("hold/3"), s.("busy?/3"),
                               "Ramal.Branch.put_write/6", s.("handle_call/3")],
          "a later write of the same action (a hook's, a record of a bulk action) joins the writes it holds"),
    step.(ramal, "Retract", ["Ramal.Capture.rollback/3", s.("undo/2"), s.("take_back/2"), s.("drop_undos/3"),
                             "Ramal.Branch.undo/2", s.("handle_call/3")],
          "a nested action fails and takes back its own writes while the outer action goes on"),
    step.(ramal, "Succeed", ["Ramal.Capture.commit/3", "Ramal.Capture.leave/1", s.("release/1"), s.("commit/1"),
                             s.("commit_writes/2"), "Ramal.Branch.delta/2",
                             s.("handle_cast/2"), s.("handle_call/3")] ++ st.("append/4"),
          "the outermost action ends: a durable branch appends one delta with all its writes before it returns"),
    step.(ramal, "Usable", [s.("usable?/1")], "open and not claimed by a merge: what a read, a write and a fork need"),
    step.(ramal, "Fail", ["Ramal.Capture.rollback/3", s.("undo/2"), s.("update/2"), s.("take_back/2"),
                          "Ramal.Branch.undo/2"],
          "an action that fails takes back every write it still holds, newest first"),
    step.(ramal, "Crash", [], "the process running an action dies; Down takes its writes back"),
    step.(ramal, "ForkIt", ["Ramal.fork/2", "Ramal.Branch.fork/2", s.("fork_source/1"), s.("start_forked/2"),
                            s.("without_running/1")] ++ st.("put/2"),
          "a fork is taken without the writes of actions still running"),
    step.(ramal, "Propose", ["Ramal.propose/2", s.("propose/2"), "Ramal.Branch.propose/4"],
          "a proposal waits for running actions and is persisted before the call returns"),
    step.(ramal, "Close", ["Ramal.reject/2", "Ramal.discard/1", s.("reject/2"), s.("discard/1"),
                           "Ramal.Branch.discard/1"],
          "reject and discard persist, then stop"),
    step.(ramal, "Claim", ["Ramal.merge/2", "Ramal.approve/2", s.("begin_merge/2"), "Ramal.Merge.claim_and_merge/4"],
          "a merge claims the branch once the running actions end"),
    step.(ramal, "Commit", ["Ramal.Merge.merge/3", "Ramal.Merge.check_staleness/2", "Ramal.Merge.replay/3",
                            "Ramal.Merge.mark_merged/2"] ++ st.("mark_merged/2"),
          "one transaction checks staleness, replays the log and stores the branch as merged"),
    step.(ramal, "MarkRefused", ["Ramal.Merge.mark_merged/2", "Ramal.Merge.finish/4"] ++ st.("mark_merged/2"),
          "the mark finds the branch already merged"),
    step.(ramal, "Abort", ["Ramal.Merge.finish/3", "Ramal.Merge.finish/4", s.("finish_merge/2")],
          "a stale base or a failing replay rolls back and releases the claim"),
    step.(ramal, "Finish", [s.("finish_merge/2"), s.("finish_merge/3"), s.("stop_merged/1"), s.("merged_state/1")],
          "the merged branch is persisted and stopped, or kept loaded as merged"),
    step.(ramal, "Forget", [], "the merging caller forgets its result"),
    step.(ramal, "MergerDies", [s.("handle_info/2"), s.("stored_merged?/1"), s.("stop_merged/1")],
          "the merging process dies after the commit; the process asks the storage before releasing the claim"),
    step.(ramal, "Compact", [s.("compact/1"), s.("compacted/1"), s.("compact_recovered/2")] ++ st.("put/2"),
          "a snapshot without the running actions' writes covers the write log"),

    # -- tla/Nested.tla: a nested fork merging into its parent ------------------------------------------------------
    step.(nested, "ParentWrite", [s.("capture/3"), "Ramal.Capture.write/4"], "an action in the parent"),
    step.(nested, "Fork", ["Ramal.fork/2", "Ramal.Branch.fork/2"], "a nested fork starts with the parent's log"),
    step.(nested, "ChildWrite", [s.("capture/3"), "Ramal.Capture.write/4", s.("usable?/1")],
          "an action in the fork; a claimed fork takes none"),
    step.(nested, "Claim", [s.("begin_merge/2")], "the fork is claimed"),
    step.(nested, "Snapshot", [s.("merge_source/1"), "Ramal.Merge.merge_source/2"],
          "the parent is copied with its version"),
    step.(nested, "Refuse", ["Ramal.Merge.not_adopted/2"], "a fork the parent holds is not merged again"),
    step.(nested, "Replay", ["Ramal.Merge.replay_in_scratch/4", "Ramal.Branch.own_entries/1"],
          "the fork's own entries are replayed in the copy"),
    step.(nested, "Abort", ["Ramal.Merge.merge_nested/4", s.("finish_merge/2")], "a replay fails or the persist is refused"),
    step.(nested, "Adopt", [s.("adopt/4"), "Ramal.Branch.adopt/3"], "the parent takes the copy if its version is unchanged"),
    step.(nested, "Finish", [s.("finish_merge/2"), s.("finish_merge/3")], "the fork is stored as merged"),
    step.(nested, "Dies", [s.("handle_info/2"), s.("adopted?/2"), s.("adopted/1"), s.("found_adopted/2")],
          "the merger dies; a fork the parent holds is merged when its process notices"),
    step.(nested, "NodeCrash", [], "the node restarts"),

    # -- tla/Cluster.tla: one branch in a cluster ------------------------------------------------------------------
    step.(cluster, "Load", [s.("init/1"), "Ramal.Cluster.register_name/2"] ++ st.("claim/2"),
          "a process wins the name and claims the branch, which bumps the storage's epoch"),
    step.(cluster, "Write", [s.("commit/1"), s.("commit_writes/2")] ++ st.("append/4"),
          "an append is refused unless the process holds the storage's epoch"),
    step.(cluster, "Unload", [s.("terminate/2"), s.("fence/2")] ++ st.("put/2"),
          "a save is refused when the process is not on the storage's epoch"),
    step.(cluster, "Split", [], "the network splits"),
    step.(cluster, "Heal", ["Ramal.Cluster.resolve/3", s.("handle_cast/2")],
          "the process with the higher epoch keeps the name"),
    step.(cluster, "Crash", [], "a node crashes"),

    # -- bend/model.bend: the data rules ---------------------------------------------------------------------------
    step.(bend, "put_created", ["Ramal.Overlay.put_created/3"], "how a create combines with the entry there"),
    step.(bend, "put_updated", ["Ramal.Overlay.put_updated/3"], "how an update combines with the entry there"),
    step.(bend, "put_deleted", ["Ramal.Overlay.put_deleted/2"], "how a destroy combines with the entry there"),
    step.(bend, "view", ["Ramal.Overlay.patch/4"], "what a read in the branch sees of a row"),
    step.(bend, "capture", ["Ramal.Capture.write/4", "Ramal.Branch.put_write/6"],
          "the branch runs the action on what it sees and records the write"),
    step.(bend, "run", ["Ramal.Merge.replay/3", "Ramal.Merge.replay_entry/4"], "the merge replays the log on the base"),
    step.(bend, "put_entry", ["Ramal.Overlay.merge_into/2"], "a fork copies its parent entry by entry"),
    step.(bend, "rename", ["Ramal.Merge.rename_entry/2", "Ramal.Merge.rename_value/2"],
          "the merge swaps a placeholder key for the key the database gave the row (ADR 0042)")
  ],

  # Files under lib/ that hold no modelled function, and why no model needs them. "tests" names what checks them instead.
  not_modelled: %{
    "lib/mix/tasks/ramal.doctor.ex" => "a command that reports the Ash contract; it starts no branch work",
    "lib/mix/tasks/ramal.gen.migration.ex" =>
      "writes the storage tables; the columns' behaviour is checked in test/ramal/storage_postgres_test.exs and owner_test.exs",
    "lib/ramal/aggregate.ex" => "read side, tests: test/ramal/aggregate_property_test.exs",
    "lib/ramal/ash.ex" => "the Ash contract and its seams; a refusal only removes steps of the model (ADR 0049)",
    "lib/ramal/ash/contract.ex" => "the Ash contract checks; a refusal only removes steps of the model (ADR 0049)",
    "lib/ramal/ash/probe.ex" => "resources the contract checks run on",
    "lib/ramal/change.ex" => "the struct diff returns; diff is read only, tests: test/ramal/diff_fork_test.exs",
    "lib/ramal/collation.ex" => "read side, tests: test/ramal/collation_test.exs",
    "lib/ramal/current.ex" => "which branch the calling process is in; the model lets a caller pick any branch",
    "lib/ramal/error.ex" => "the error struct",
    "lib/ramal/limits.ex" => "refuses to create branches over a limit; a refusal removes steps of the model, tests: limits_test.exs",
    "lib/ramal/merge/result.ex" => "the struct merge returns",
    "lib/ramal/raw_query_guard.ex" =>
      "a telemetry handler that reports raw Ecto queries inside a branch; it reads, never changes a branch (ADR 0053), tests: test/ramal/raw_query_guard_test.exs",
    "lib/ramal/prefilter.ex" => "read side, tests: test/ramal/prefilter_test.exs",
    "lib/ramal/preparation.ex" => "read side, tests: test/ramal/overlay_property_test.exs and the preparation tests",
    "lib/ramal/preparation/aggregates.ex" => "read side, tests: test/ramal/aggregate_test.exs",
    "lib/ramal/preparation/fragments.ex" => "read side, tests: test/ramal/fragment_filter_test.exs",
    "lib/ramal/preparation/fragments/postgres.ex" => "read side, tests: test/ramal/fragment_filter_test.exs",
    "lib/ramal/preparation/lateral.ex" => "read side, tests: test/ramal/through_test.exs",
    "lib/ramal/preparation/many_to_many.ex" => "read side, tests: test/ramal/many_to_many_test.exs",
    "lib/ramal/preparation/placeholders.ex" => "read side, tests: test/ramal/placeholder_order_test.exs",
    "lib/ramal/preparation/paged.ex" => "read side, tests: test/ramal/paginated_read_test.exs",
    "lib/ramal/preparation/related.ex" => "read side, tests: test/ramal/relationship_filter_test.exs",
    "lib/ramal/resource.ex" => "the Spark extension that installs the read preparation and the write change",
    "lib/ramal/resource/transformer.ex" => "the extension's transformer",
    "lib/ramal/storage/codec.ex" => "a branch to JSON and back, tests: test/ramal/codec_test.exs",
    "lib/ramal/telemetry.ex" => "event names",
    "lib/ramal/tools.ex" => "the tool definitions for an LLM agent; they call the public API"
  }
}
