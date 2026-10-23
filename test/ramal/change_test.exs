defmodule Ramal.ChangeTest do
  use ExUnit.Case, async: true

  alias Ramal.Change
  alias Ramal.Test.Other.{Credential, Note}

  describe "redact/1" do
    test "replaces the values of sensitive attributes and keeps the others" do
      change = %Change{
        resource: Credential,
        key: 1,
        kind: :updated,
        changes: %{secret: {"old", "new"}, label: {"a", "b"}}
      }

      assert Change.redact(change).changes == %{
               secret: {"[redacted]", "[redacted]"},
               label: {"a", "b"}
             }
    end

    test "leaves a resource without sensitive attributes as it is" do
      change = %Change{resource: Note, key: 1, kind: :created, changes: %{text: {nil, "hi"}}}

      assert Change.redact(change) == change
    end

    test "leaves an attribute the resource does not have, and a module that is not a resource, as they are" do
      change = %Change{resource: Credential, key: 1, kind: :created, changes: %{ghost: {nil, 1}}}
      assert Change.redact(change) == change

      plain = %Change{resource: String, key: 1, kind: :created, changes: %{secret: {nil, 1}}}
      assert Change.redact(plain) == plain
    end
  end
end
