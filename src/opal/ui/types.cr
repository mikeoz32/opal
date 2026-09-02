module LF::UI
  # Semantic color used by controls and feedback components.
  enum Tone
    Neutral
    Primary
    Success
    Warning
    Danger
  end

  # Shared component sizing scale.
  enum Size
    Small
    Medium
    Large
  end

  enum ButtonVariant
    Solid
    Outline
    Ghost
  end

  enum MenuAlign
    Start
    End
  end

  enum TabsOrientation
    Horizontal
    Vertical
  end

  # One option rendered by `UI.select`.
  struct SelectOption
    getter value : String
    getter label : String
    getter? disabled : Bool

    def initialize(@value, @label, @disabled = false)
    end
  end
end
