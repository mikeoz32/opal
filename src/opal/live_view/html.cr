module LF::LiveView::HTML
  extend self

  def escape(value) : String
    String.build do |output|
      value.to_s.each_char do |char|
        case char
        when '&'  then output << "&amp;"
        when '<'  then output << "&lt;"
        when '>'  then output << "&gt;"
        when '"'  then output << "&quot;"
        when '\'' then output << "&#39;"
        else           output << char
        end
      end
    end
  end
end
