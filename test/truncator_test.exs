defmodule TruncatorTest do
  use ExUnit.Case
  alias ZenMonitor.Truncator

  describe "scalars should pass through" do
    test "atoms" do
      assert :test_atom == Truncator.truncate(:test_atom)
    end

    test "floats" do
      assert 1.2 == Truncator.truncate(1.2)
    end

    test "integers" do
      assert 1 == Truncator.truncate(1)
    end

    test "strings" do
      assert "hello" == Truncator.truncate("hello")
    end

    test "pids" do
      pid = self()
      assert pid == Truncator.truncate(pid)
    end
  end

  describe "top level shutdown messages should pass through" do
    test "long list that would normally be truncated" do
      long_list = [:a, :b, :c, :d, :e, :f, :g]
      assert {:shutdown, ^long_list} = Truncator.truncate({:shutdown, long_list})
    end

    test "only at top level, nested shutdown tuples should be truncated" do
      long_list = [:a, :b, :c, :d, :e, :f, :g]
      assert {:foo, {:shutdown, :truncated}} = Truncator.truncate({:foo, {:shutdown, long_list}})
    end
  end

  describe "bistring truncation" do
    test "less than limit should pass through" do
      input = "test-string"
      assert input == Truncator.truncate(input)
    end

    test "equal to limit should pass through" do
      input = String.duplicate("a", 1024)
      assert input == Truncator.truncate(input)
    end

    test "greater than limit should be truncated" do
      assert <<_::binary-size(1021), "...">> = Truncator.truncate(String.duplicate("a", 2048))
    end
  end

  describe "list truncation" do
    test "lists of size less than 5 should pass through" do
      assert [] == Truncator.truncate([])
      assert [1] == Truncator.truncate([1])
      assert [1, 2] == Truncator.truncate([1, 2])
      assert [1, 2, 3] == Truncator.truncate([1, 2, 3])
      assert [1, 2, 3, 4] == Truncator.truncate([1, 2, 3, 4])
    end

    test "lists of size 5 should be truncated" do
      assert :truncated == Truncator.truncate([1, 2, 3, 4, 5])
    end

    test "lists of size greater than 5 should be truncated" do
      assert :truncated == Truncator.truncate([1, 2, 3, 4, 5, 6])
    end
  end

  describe "tuple truncation" do
    test "tuples of size less than 5 should pass through" do
      assert {} == Truncator.truncate({})
      assert {1} == Truncator.truncate({1})
      assert {1, 2} == Truncator.truncate({1, 2})
      assert {1, 2, 3} == Truncator.truncate({1, 2, 3})
      assert {1, 2, 3, 4} == Truncator.truncate({1, 2, 3, 4})
    end

    test "tuples of size 5 should be truncated" do
      assert :truncated = Truncator.truncate({1, 2, 3, 4, 5})
    end

    test "tuples of size greater than 5 should be truncated" do
      assert :truncated = Truncator.truncate({1, 2, 3, 4, 5, 6})
    end
  end

  describe "map truncation" do
    test "maps of size less than 5 should pass through" do
      assert %{a: 1} == Truncator.truncate(%{a: 1})
      assert %{a: 1, b: 2} == Truncator.truncate(%{a: 1, b: 2})
      assert %{a: 1, b: 2, c: 3} == Truncator.truncate(%{a: 1, b: 2, c: 3})
      assert %{a: 1, b: 2, c: 3, d: 4} == Truncator.truncate(%{a: 1, b: 2, c: 3, d: 4})
    end

    test "maps of size 5 should be truncated" do
      assert :truncated == Truncator.truncate(%{a: 1, b: 2, c: 3, d: 4, e: 5})
    end

    test "maps of size greater than 5 should be truncated" do
      assert :truncated == Truncator.truncate(%{a: 1, b: 2, c: 3, d: 4, e: 5, f: 6})
    end
  end

  describe "struct truncation" do
    defmodule OneFieldStruct do
      defstruct a: 1
    end

    defmodule TwoFieldStruct do
      defstruct a: 1, b: 2
    end

    defmodule ThreeFieldStruct do
      defstruct a: 1, b: 2, c: 3
    end

    defmodule FourFieldStruct do
      defstruct a: 1, b: 2, c: 3, d: 4
    end

    defmodule FiveFieldStruct do
      defstruct a: 1, b: 2, c: 3, d: 4, e: 5
    end

    defmodule SixFieldStruct do
      defstruct a: 1, b: 2, c: 3, d: 4, e: 5, f: 6
    end

    test "structs of size less than 5 should pass through" do
      one = %OneFieldStruct{}
      two = %TwoFieldStruct{}
      three = %ThreeFieldStruct{}
      four = %FourFieldStruct{}

      assert one == Truncator.truncate(one)
      assert two == Truncator.truncate(two)
      assert three == Truncator.truncate(three)
      assert four == Truncator.truncate(four)
    end

    test "structs of size 5 should be truncated" do
      assert :truncated == Truncator.truncate(%FiveFieldStruct{})
    end

    test "structs of size greater than 5 should be truncated" do
      assert :truncated == Truncator.truncate(%SixFieldStruct{})
    end
  end

  describe "struct robustness" do
    test "small unknown struct loses its struct key" do
      unknown_struct = %{
        :__struct__ => NotARealModule,
        a: :b,
        c: :d
      }

      assert %{a: :b, c: :d} == Truncator.truncate(unknown_struct)
    end

    test "large unknown struct should be truncated" do
      unknown_struct = %{
        :__struct__ => NotARealModule,
        a: :b,
        c: :d,
        e: :f,
        g: :h,
        i: :j,
      }

      assert :truncated == Truncator.truncate(unknown_struct)
    end
  end

  describe "limited nesting" do
    defmodule Nested do
      defstruct map: %{},
                list: [],
                tuple: {},
                struct: nil
    end

    test "it should prevent deeply nested lists" do
      nested = [:a, [:b, [:c, [:d, [:e, [:f]]]]]]

      assert :truncated == Truncator.truncate(nested, 0)
      assert [:truncated, :truncated] == Truncator.truncate(nested, 1)
      assert [:a, [:truncated, :truncated]] == Truncator.truncate(nested, 2)
      assert [:a, [:b, [:truncated, :truncated]]] == Truncator.truncate(nested, 3)
      assert [:a, [:b, [:c, [:truncated, :truncated]]]] == Truncator.truncate(nested, 4)
    end

    test "it should prevent deeply nested maps" do
      nested = %{a: %{b: %{c: %{d: %{}}}}}

      assert :truncated == Truncator.truncate(nested, 0)
      assert %{a: :truncated} == Truncator.truncate(nested, 1)
      assert %{a: %{b: :truncated}} == Truncator.truncate(nested, 2)
      assert %{a: %{b: %{c: :truncated}}} == Truncator.truncate(nested, 3)
      assert %{a: %{b: %{c: %{d: :truncated}}}} == Truncator.truncate(nested, 4)
      assert nested == Truncator.truncate(nested, 5)
    end

    test "it should prevent deeply nested tuples" do
      nested = {:a, {:b, {:c, {:d, {}}}}}

      assert :truncated == Truncator.truncate(nested, 0)
      assert {:truncated, :truncated} == Truncator.truncate(nested, 1)
      assert {:a, {:truncated, :truncated}} == Truncator.truncate(nested, 2)
      assert {:a, {:b, {:truncated, :truncated}}} == Truncator.truncate(nested, 3)
      assert {:a, {:b, {:c, {:truncated, :truncated}}}} == Truncator.truncate(nested, 4)
      assert {:a, {:b, {:c, {:d, {}}}}} == Truncator.truncate(nested, 5)
    end

    test "it should prevent deeply nested structs" do
      assert %Nested{map: :truncated} = Truncator.truncate(%Nested{map: %{a: 1}}, 1)

      assert %Nested{map: %{a: :truncated}} = Truncator.truncate(%Nested{map: %{a: %{b: 2}}}, 2)

      assert %Nested{list: :truncated} = Truncator.truncate(%Nested{list: [1, [2, [3]]]}, 1)

      assert %Nested{list: [:truncated, :truncated]} =
               Truncator.truncate(%Nested{list: [1, [2, [3]]]}, 2)

      assert %Nested{struct: :truncated} =
               Truncator.truncate(%Nested{struct: MapSet.new([1, 2, 3])}, 1)

      assert %Nested{struct: %MapSet{map: :truncated}} =
               Truncator.truncate(%Nested{struct: MapSet.new([1, 2, 3])}, 2)

      assert %Nested{tuple: :truncated} =
               Truncator.truncate(%Nested{tuple: {:a, {:b, {:c, {}}}}}, 1)

      assert %Nested{tuple: {:truncated, :truncated}} =
               Truncator.truncate(%Nested{tuple: {:a, {:b, {:c, {}}}}}, 2)

      assert %Nested{tuple: {:a, {:truncated, :truncated}}} =
               Truncator.truncate(%Nested{tuple: {:a, {:b, {:c, {}}}}}, 3)
    end
  end
end
