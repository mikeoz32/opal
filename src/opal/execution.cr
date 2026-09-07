# Transport-neutral policy contracts and deterministic pipeline orchestration.
# Concrete transports select their own context, value, metadata, and result
# types by instantiating these generic contracts.
module LF::Execution
  abstract class Guard(Context)
    abstract def can_activate(context : Context) : Bool
  end

  abstract class Pipe(Value, Metadata, Context)
    abstract def transform(value : Value, metadata : Metadata, context : Context) : Value
  end

  abstract class Interceptor(Context, Result)
    abstract def intercept(context : Context, call_next : Proc(Result)) : Result
  end

  abstract class Filter(Context, Result)
    abstract def catch(exception : Exception, context : Context) : Result?
  end

  module Pipeline
    def self.authorized?(
      context : Context,
      guards,
    ) : Bool forall Context
      guards.all? { |guard| guard.can_activate(context) }
    end

    def self.apply_pipes(
      value : Value,
      metadata : Metadata,
      context : Context,
      pipes,
    ) : Value forall Value, Metadata, Context
      pipes.reduce(value) do |current, pipe|
        pipe.transform(current, metadata, context)
      end
    end

    def self.intercept(
      context : Context,
      interceptors,
      &action : -> Result
    ) : Result forall Context, Result
      return yield if interceptors.empty?
      InterceptorChain(Context, Result, typeof(interceptors)).new(context, interceptors, action).call
    end

    def self.catch(
      exception : Exception,
      context,
      filters,
    )
      filters.each do |filter|
        if result = filter.catch(exception, context)
          return result
        end
      end
      nil
    end

    private class InterceptorChain(Context, Result, Interceptors)
      def initialize(
        @context : Context,
        @interceptors : Interceptors,
        @action : Proc(Result),
      )
      end

      def call(index : Int32 = 0) : Result
        return @action.call if index >= @interceptors.size

        interceptor = @interceptors[index]
        interceptor.intercept(@context, -> { call(index + 1) })
      end
    end
  end
end
