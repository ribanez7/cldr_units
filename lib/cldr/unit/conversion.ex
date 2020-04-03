defmodule Cldr.Unit.Conversion do
  @moduledoc """
  Unit conversion functions for the units defined
  in `Cldr`.

  """

  @enforce_keys [:factor, :offset, :base_unit]
  defstruct [
    factor: 1,
    offset: 0,
    base_unit: nil
  ]

  @type t :: %{
    factor: integer | float | Ratio.t(),
    base_unit: [atom(), ...],
    offset: integer | float
  }

  alias Cldr.Unit

  import Unit, only: [incompatible_units_error: 2]

  defmodule Options do
    defstruct [usage: nil, locale: nil, backend: nil, territory: nil]
  end

  @doc """
  Convert one unit into another unit of the same
  unit type (length, volume, mass, ...)

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  * `to_unit` is any unit name returned by `Cldr.Unit.units/0`

  ## Returns

  * a `Unit.t` of the unit type `to_unit` or

  * `{:error, {exception, message}}`

  ## Examples

      iex> Cldr.Unit.convert Cldr.Unit.new!(:celsius, 0), :fahrenheit
      #Cldr.Unit<:fahrenheit, 32>

      iex> Cldr.Unit.convert Cldr.Unit.new!(:fahrenheit, 32), :celsius
      #Cldr.Unit<:celsius, 0>

      iex> Cldr.Unit.convert Cldr.Unit.new!(:mile, 1), :foot
      #Cldr.Unit<:foot, 5280>

      iex> Cldr.Unit.convert Cldr.Unit.new!(:mile, 1), :gallon
      {:error, {Cldr.Unit.IncompatibleUnitsError,
        "Operations can only be performed between units of the same category. Received :mile and :gallon"}}

  """
  @spec convert(Unit.t(), Unit.unit()) :: Unit.t() | {:error, {module(), String.t()}}

  def convert(%Unit{unit: from_unit, value: _value} = unit, from_unit) do
    unit
  end

  def convert(%Unit{} = unit, to_unit) do
    %{unit: from_unit, value: value, base_conversion: from_conversion} = unit

    with {:ok, to_unit, to_conversion} <- Unit.validate_unit(to_unit),
         true <- Unit.compatible?(from_unit, to_unit),
         {:ok, converted} <- convert(value, from_conversion, to_conversion) do
      Unit.new(to_unit, converted)
    else
      {:error, _} = error -> error
      false -> {:error, incompatible_units_error(from_unit, to_unit)}
    end
  end

  defp convert(value, from, to) when is_number(value) or is_map(value) do
    use Ratio

    value
    |> Ratio.new
    |> convert_to_base(from)
    # |> IO.inspect(label: "Base conversion")
    |> convert_from_base(to)
    # |> IO.inspect(label: "To conversion")
    |> to_original_number_type(value)
    |> wrap_ok
    # |> maybe_truncate
  end

  defp convert(_value, from, to) do
    {:error,
     {Cldr.Unit.UnitNotConvertibleError,
      "No conversion is possible between #{inspect(to)} and #{inspect(from)}"}}
  end

  def convert_to_base(value, %__MODULE__{} = from) do
    use Ratio
    # IO.inspect value, label: "Value"
    # IO.inspect from, label: "From Conversion factor"
    %{factor: from_factor, offset: from_offset} = from
    (value * from_factor) + from_offset
  end

  def convert_to_base(value, {_, %__MODULE__{} = from}) do
    convert_to_base(value, from)
  end

  def convert_to_base(value, {numerator, denominator}) do
    use Ratio

    convert_to_base(value, numerator) / convert_to_base(value, denominator)
  end

  def convert_to_base(value, []) do
    value
  end

  def convert_to_base(value, [numerator | rest]) do
    use Ratio

    convert_to_base(value, numerator) |> convert_to_base(rest)
  end

  def convert_from_base(value, %__MODULE__{} = to) do
    use Ratio
    # IO.inspect value, label: "Value"
    # IO.inspect to, label: "To Conversion factor"
    %{factor: to_factor, offset: to_offset} = to
    ((value - to_offset) / to_factor)
  end

  def convert_from_base(value, {_, %__MODULE__{} = to}) do
    convert_from_base(value, to)
  end

  def convert_from_base(value, {numerator, denominator}) do
    use Ratio
    # IO.inspect [numerator, denominator], label: "num/denom"
    convert_from_base(value, numerator) / convert_from_base(value, denominator)
  end

  def convert_from_base(value, []) do
    value
  end

  def convert_from_base(value, [numerator | rest]) do
    use Ratio

    convert_from_base(value, numerator) |> convert_from_base(rest)
  end

  defp to_original_number_type(%Ratio{} = converted, value) when is_number(value) do
    %Ratio{numerator: numerator, denominator: denominator} = converted

    numerator / denominator
  end

  defp to_original_number_type(%Ratio{} = converted, %Decimal{} = _value) do
    %Ratio{numerator: numerator, denominator: denominator} = converted

    Decimal.new(numerator)
    |> Decimal.div(Decimal.new(denominator))
  end

  defp to_original_number_type(converted, value) when is_number(value) do
    converted
  end

  defp to_original_number_type(converted, %Decimal{} = _value) do
    Decimal.new(converted)
  end

  def maybe_truncate(converted) when is_number(converted) do
    truncated = trunc(converted)

    if converted == truncated do
      truncated
    else
      converted
    end
  end

  def maybe_truncate(%Decimal{} = converted) do
    truncated = Decimal.round(converted, 0, :down)

    if converted == truncated do
      truncated
    else
      converted
    end
  end

  def wrap_ok(unit) do
    {:ok, unit}
  end

  @doc """
  Convert one unit into another unit of the same
  unit type (length, volume, mass, ...) and raises
  on a unit type mismatch

  ## Arguments

  * `unit` is any unit returned by `Cldr.Unit.new/2`

  * `to_unit` is any unit name returned by `Cldr.Unit.units/0`

  ## Returns

  * a `Unit.t` of the unit type `to_unit` or

  * raises an exception

  ## Examples

      iex> Cldr.Unit.Conversion.convert! Cldr.Unit.new!(:celsius, 0), :fahrenheit
      #Cldr.Unit<:fahrenheit, 32>

      iex> Cldr.Unit.Conversion.convert! Cldr.Unit.new!(:fahrenheit, 32), :celsius
      #Cldr.Unit<:celsius, 0>

      Cldr.Unit.Conversion.convert Cldr.Unit.new!(:mile, 1), :gallon
      ** (Cldr.Unit.IncompatibleUnitsError) Operations can only be performed between units of the same type. Received :mile and :gallon

  """
  @spec convert!(Unit.t(), Unit.unit()) :: Unit.t() | no_return()

  def convert!(%Unit{} = unit, to_unit) do
    case convert(unit, to_unit) do
      {:error, {exception, reason}} -> raise exception, reason
      unit -> unit
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

      iex> u = Cldr.Unit.new(:kilometer, 10)
      #Cldr.Unit<:kilometer, 10>
      iex> Cldr.Unit.Conversion.convert_to_base_unit u
      #Cldr.Unit<:meter, 10000>

  """
  def convert_to_base_unit(%Unit{} = unit) do
    with {:ok, base_unit} <- Unit.base_unit(unit) do
      convert(unit, base_unit)
    end
  end

  def convert_to_base_unit(unit) when is_atom(unit) do
    unit
    |> Unit.new(1)
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

      iex> u = Cldr.Unit.new(:kilometer, 10)
      #Cldr.Unit<:kilometer, 10>
      iex> Cldr.Unit.Conversion.convert_to_base_unit u
      #Cldr.Unit<:meter, 10000>

  """
  def convert_to_base_unit!(%Unit{} = unit) do
    case convert_to_base_unit(unit) do
      {:error, {exception, reason}} -> raise exception, reason
      unit -> unit
    end
  end

end
