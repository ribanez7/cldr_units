defmodule Cldr.Unit.Conversion do
  @moduledoc """
  Unit conversion functions for the units defined
  in `Cldr`.

  """

  @enforce_keys [:factor, :offset, :base_unit]
  defstruct factor: 1,
            offset: 0,
            base_unit: nil

  @type factor :: integer | float | Ratio.t()
  @type offset :: integer | float

  @type t :: %{
          factor: factor(),
          base_unit: [atom(), ...],
          offset: offset()
        }

  alias Cldr.Unit
  alias Cldr.Unit.BaseUnit

  import Kernel, except: [div: 2]

  @doc """
  Returns the conversion that calculates
  the base unit into another unit or
  and error.

  """
  def conversion_for(unit_1, unit_2) do
    with {:ok, base_unit_1, _conversion_1} <- base_unit_and_conversion(unit_1),
         {:ok, base_unit_2, conversion_2} <- base_unit_and_conversion(unit_2) do
      conversion_for(unit_1, unit_2, base_unit_1, base_unit_2, conversion_2)
    end
  end

  # Base units match so are compatible
  defp conversion_for(_unit_1, _unit_2, base_unit, base_unit, conversion_2) do
    {:ok, conversion_2, :forward}
  end

  # Its invertable so see if that's convertible. Note that
  # there is no difference in the conversion for an inverted
  # conversion. Its only a hint so that in convert_from_base/2
  # we know to divide, not multiple the value.

  defp conversion_for(unit_1, unit_2, base_unit_1, _base_unit_2, {numerator_2, denominator_2}) do
    inverted_conversion = {denominator_2, numerator_2}

    with {:ok, base_unit_2} <- BaseUnit.canonical_base_unit(inverted_conversion) do
      if base_unit_1 == base_unit_2 do
        {:ok, {numerator_2, denominator_2}, :inverted}
      else
        {:error, Unit.incompatible_units_error(unit_1, unit_2)}
      end
    end
  end

  # If the base units don't match, try comparing the unit categories
  # instead.

  defp conversion_for(unit_1, unit_2, _base_unit_1, _base_unit_2, conversion_2) do
    with {:ok, category_1} <- Cldr.Unit.unit_category(unit_1),
         {:ok, category_2} <- Cldr.Unit.unit_category(unit_2) do
      if category_1 == category_2 do
        {:ok, conversion_2, :forward}
      else
        {:error, Unit.incompatible_units_error(unit_1, unit_2)}
      end
    end
  end

  @doc """
  Returns the base unit and the base unit
  conversionfor a given unit.

  ## Argument

  * `unit` is either a `t:Cldr.Unit`, an `atom` or
    a `t:String`

  ## Returns

  * `{:ok, base_unit, conversion}` or

  * `{:error, {exception, reason}}`

  ## Example

      iex> Cldr.Unit.Conversion.base_unit_and_conversion :square_kilometer
      {
        :ok,
        :square_meter,
        [square_kilometer: %Cldr.Unit.Conversion{base_unit: [:square, :meter], factor: 1000000, offset: 0}]
      }

      iex> Cldr.Unit.Conversion.base_unit_and_conversion :square_table
      {:error, {Cldr.UnknownUnitError, "Unknown unit was detected at \\"table\\""}}

  """

  def base_unit_and_conversion(%Unit{base_conversion: conversion}) do
    {:ok, base_unit} = BaseUnit.canonical_base_unit(conversion)
    {:ok, base_unit, conversion}
  end

  def base_unit_and_conversion(unit_name) when is_atom(unit_name) or is_binary(unit_name) do
    with {:ok, _unit, conversion} <- Cldr.Unit.validate_unit(unit_name),
         {:ok, base_unit} <- BaseUnit.canonical_base_unit(conversion) do
      {:ok, base_unit, conversion}
    end
  end

  @doc """
  Convert one unit into another unit of the same
  unit type (length, volume, mass, ...)

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  * `to_unit` is any unit name returned by `Cldr.Unit.known_units/0`

  ## Returns

  * a `Unit.t` of the unit type `to_unit` or

  * `{:error, {exception, message}}`

  ## Examples

      iex> Cldr.Unit.convert Cldr.Unit.new!(:mile, 1), :foot
      {:ok, Cldr.Unit.new!(:foot, 5280)}

      iex> Cldr.Unit.convert Cldr.Unit.new!(:mile, 1), :gallon
      {:error, {Cldr.Unit.IncompatibleUnitsError,
        "Operations can only be performed between units with the same base unit. Received :mile and :gallon"}}

  """
  @spec convert(Unit.t(), Unit.unit()) :: {:ok, Unit.t()} | {:error, {module(), String.t()}}

  def convert(%Unit{value: value, base_conversion: from_conversion} = unit, to_unit) do
    with {:ok, to_conversion, maybe_inverted} <- conversion_for(unit, to_unit) do
      converted_value = convert(value, from_conversion, to_conversion, maybe_inverted)
      Unit.new(to_unit, converted_value, usage: unit.usage, format_options: unit.format_options)
    end
  end

  defp convert(value, from, to, maybe_inverted) when is_number(value) or is_map(value) do
    value
    |> convert_to_base(from)
    |> maybe_invert_value(maybe_inverted)
    |> convert_from_base(to)
  end

  def maybe_invert_value(value, :inverted) do
    div(1, value)
  end

  def maybe_invert_value(value, _) do
    value
  end

  # All conversions are ultimately a list of
  # 2-tuples of the unit and conversion struct
  defp convert_to_base(value, {_, %__MODULE__{} = from}) do
    %{factor: from_factor, offset: from_offset} = from

    from_factor
    |> mult(value)
    |> add(from_offset)
  end

  # A per module is a 2-tuple of the numerator and
  # denominator. Both are lists of conversion tuples.
  defp convert_to_base(value, {numerator, denominator}) do
    convert_to_base(1.0, numerator)
    |> div(convert_to_base(1.0, denominator))
    |> mult(value)
  end

  # We recurse over the list of conversions
  # and accumulate the value as we go
  defp convert_to_base(value, []) do
    value
  end

  defp convert_to_base(value, [first | rest]) do
    convert_to_base(value, first) |> convert_to_base(rest)
  end

  # But if we meet a shape of data we don't
  # understand then its a raisable error
  defp convert_to_base(_value, conversion) do
    raise ArgumentError, "Conversion not recognised: #{inspect(conversion)}"
  end

  defp convert_from_base(value, {_, %__MODULE__{} = to}) do
    %{factor: to_factor, offset: to_offset} = to

    value
    |> sub(to_offset)
    |> div(to_factor)
  end

  defp convert_from_base(value, {numerator, denominator}) do
    convert_from_base(1.0, numerator)
    |> div(convert_from_base(1.0, denominator))
    |> mult(value)
  end

  defp convert_from_base(value, []) do
    value
  end

  defp convert_from_base(value, [first | rest]) do
    convert_from_base(value, first) |> convert_from_base(rest)
  end

  defp convert_from_base(_value, conversion) do
    raise ArgumentError, "Conversion not recognised: #{inspect(conversion)}"
  end

  @doc """
  Convert one unit into another unit of the same
  unit type (length, volume, mass, ...) and raises
  on a unit type mismatch

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  * `to_unit` is any unit name returned by `Cldr.Unit.known_units/0`

  ## Returns

  * a `Unit.t` of the unit type `to_unit` or

  * raises an exception

  ## Examples

      iex> Cldr.Unit.Conversion.convert!(Cldr.Unit.new!(:celsius, 0), :fahrenheit)
      ...> |> Cldr.Unit.round
      Cldr.Unit.new!(:fahrenheit, 32.0)

      iex> Cldr.Unit.Conversion.convert!(Cldr.Unit.new!(:fahrenheit, 32), :celsius)
      ...> |> Cldr.Unit.round
      Cldr.Unit.new!(:celsius, 0.0)

      Cldr.Unit.Conversion.convert Cldr.Unit.new!(:mile, 1), :gallon
      ** (Cldr.Unit.IncompatibleUnitsError) Operations can only be performed between units of the same type. Received :mile and :gallon

  """
  @spec convert!(Unit.t(), Unit.unit()) :: Unit.t() | no_return()

  def convert!(%Unit{} = unit, to_unit) do
    case convert(unit, to_unit) do
      {:error, {exception, reason}} -> raise exception, reason
      {:ok, unit} -> unit
    end
  end

  @doc """
  Convert a unit into its base unit.

  For example, the base unit for `length`
  is `meter`. The base unit is an
  intermediary unit used in all
  conversions.

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  ## Returns

  * `unit` converted to its base unit as a `t:Unit.t()` or

  * `{;error, {exception, reason}}` as an error

  ## Example

      iex> unit = Cldr.Unit.new!(:kilometer, 10)
      iex> Cldr.Unit.Conversion.convert_to_base_unit unit
      {:ok, Cldr.Unit.new!(:meter, 10000)}

  """
  def convert_to_base_unit(%Unit{} = unit) do
    with {:ok, base_unit} <- Unit.base_unit(unit) do
      convert(unit, base_unit)
    end
  end

  def convert_to_base_unit(unit) when is_atom(unit) do
    unit
    |> Unit.new!(1.0)
    |> convert_to_base_unit()
  end

  def convert_to_base_unit([unit | _rest]) when is_atom(unit) do
    convert_to_base_unit(unit)
  end

  @doc """
  Convert a unit into its base unit and
  raises on error

  For example, the base unit for `length`
  is `meter`. The base unit is an
  intermediary unit used in all
  conversions.

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  ## Returns

  * `unit` converted to its base unit as a `t:Unit.t()` or

  * raises an exception

  ## Example

      iex> unit = Cldr.Unit.new!(:kilometer, 10)
      iex> Cldr.Unit.Conversion.convert_to_base_unit! unit
      Cldr.Unit.new!(:meter, 10000)

  """
  def convert_to_base_unit!(%Unit{} = unit) do
    case convert_to_base_unit(unit) do
      {:error, {exception, reason}} -> raise exception, reason
      {:ok, unit} -> unit
    end
  end

  #### Math helpers for Ratio, float, integer

  @doc false
  def add(any, 0) do
    any
  end

  def add(any, 0.0) do
    any
  end

  def add(%Ratio{} = a, b) do
    Ratio.add(a, Ratio.new(b))
  end

  def add(a, %Ratio{} = b) do
    Ratio.add(Ratio.new(a), b)
  end

  def add(%Decimal{} = a, b) when is_float(b) do
    Decimal.add(a, Decimal.from_float(b))
  end

  def add(%Decimal{} = a, b) do
    Decimal.add(a, b)
  end

  def add(a, b) do
    a + b
  end

  @doc false
  def sub(any, 0) do
    any
  end

  def sub(any, 0.0) do
    any
  end

  def sub(%Ratio{} = a, b) do
    Ratio.sub(a, Ratio.new(b))
  end

  def sub(a, %Ratio{} = b) do
    Ratio.sub(Ratio.new(a), b)
  end

  def sub(%Decimal{} = a, b) when is_float(b) do
    Decimal.sub(a, Decimal.from_float(b))
  end

  def sub(%Decimal{} = a, b) do
    Decimal.sub(a, b)
  end

  def sub(a, b) do
    a - b
  end

  @doc false
  def mult(_any, 0) do
    0
  end

  def mult(any, 1) do
    any
  end

  def mult(any, 1.0) do
    any
  end

  def mult(1, b) do
    b
  end

  def mult(%Ratio{} = a, b) do
    case Ratio.mult(a, Ratio.new(b)) do
      %Ratio{numerator: 0, denominator: _denominator} -> 0
      %Ratio{numerator: numerator, denominator: 1} -> numerator
      ratio -> ratio
    end
  end

  def mult(a, %Ratio{} = b) do
    case Ratio.mult(Ratio.new(a), b) do
      %Ratio{numerator: 0, denominator: _denominator} -> 0
      %Ratio{numerator: numerator, denominator: 1} -> numerator
      ratio -> ratio
    end
  end

  def mult(%Decimal{} = a, b) when is_float(b) do
    Decimal.mult(a, Decimal.from_float(b))
  end

  def mult(a, %Decimal{} = b) when is_float(a) do
    Decimal.mult(Decimal.from_float(a), b)
  end

  def mult(%Decimal{} = a, b) do
    Decimal.mult(a, b)
  end

  def mult(a, %Decimal{} = b) do
    Decimal.mult(a, b)
  end

  def mult(a, b) do
    a * b
  end

  @doc false
  def div(%Ratio{numerator: numerator, denominator: 1}, 1) do
    numerator
  end

  def div(any, 1) do
    any
  end

  def div(any, 1.0) do
    any
  end

  def div(%Ratio{numerator: numerator, denominator: 1}, b) when is_float(b) do
    numerator / b
  end

  def div(%Ratio{numerator: numerator, denominator: 1}, b) when is_integer(b) do
    Kernel.div(numerator, b)
  end

  def div(%Ratio{} = a, b) do
    case Ratio.div(a, Ratio.new(b)) do
      %Ratio{numerator: 0, denominator: _denominator} -> 0
      %Ratio{numerator: numerator, denominator: 1} -> numerator
      ratio -> ratio
    end
  end

  def div(a, %Ratio{} = b) do
    case Ratio.div(Ratio.new(a), b) do
      %Ratio{numerator: 0, denominator: _denominator} -> 0
      %Ratio{numerator: numerator, denominator: 1} -> numerator
      ratio -> ratio
    end
  end

  def div(%Decimal{} = a, b) when is_float(b) do
    Decimal.div(a, Decimal.from_float(b))
  end

  def div(a, %Decimal{} = b) when is_float(a) do
    Decimal.div(Decimal.from_float(a), b)
  end

  def div(%Decimal{} = a, b) do
    Decimal.div(a, b)
  end

  def div(a, %Decimal{} = b) do
    Decimal.div(a, b)
  end

  def div(a, b) do
    a / b
  end

  @doc false
  def pow(_any, 0) do
    1
  end

  def pow(1, _any) do
    1
  end

  def pow(_any, %Ratio{numerator: 0, denominator: _denominator}) do
    1
  end

  def pow(%Ratio{} = a, %Ratio{numerator: numerator, denominator: 1}) do
    Ratio.pow(Ratio.new(a), numerator)
  end

  def pow(%Ratio{} = a, b) when is_integer(b) do
    case Ratio.pow(a, b) do
      %Ratio{numerator: 0, denominator: _denominator} -> 0
      %Ratio{numerator: numerator, denominator: 1} -> numerator
      ratio -> ratio
    end
  end

  def pow(a, b) when is_integer(b) do
    Cldr.Math.power(a, b)
  end

  def pow(a, b) do
    :math.pow(a, b)
  end

  @doc false
  def new(numerator, numerator) do
    1
  end

  def new(0, _denominator) do
    0
  end

  def new(_numerator, 0) do
    0
  end

  def new(numerator, 1) do
    numerator
  end

  def new(numerator, denominator) do
    Ratio.new(numerator, denominator)
  end
end
