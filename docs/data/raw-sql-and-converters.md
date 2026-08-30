# Raw SQL And Converters

Raw SQL is an explicit escape hatch on the transaction-local connection:

```crystal
source.transaction do |manager|
  managed = manager.find(Todo, id).not_nil!
  manager.connection.exec(
    "UPDATE todos SET title = ? WHERE id = ?",
    "changed outside the identity map",
    id
  )

  manager.clear(Todo)
  reloaded = manager.find(Todo, id)
end
```

Raw writes do not update managed objects. Call `clear(EntityType)` before
reloading and do not reuse the detached instance. Raw statements executed
directly through `connection` are application-owned; the SchemaEditor and Data
query APIs report their own statements through registered listeners.

Converters map one property to a `crystal-db` compatible stored value:

```crystal
module TimeAsString
  def self.load(result : DB::ResultSet) : Time
    Time.parse_rfc3339(result.read(String))
  end

  def self.dump(value : Time) : String
    value.to_utc.to_rfc3339
  end
end
```

Converters are stateless compile-time references, not registry entries. They
consume their own result-set column and must return a supported DB value. Bind
values are deliberately excluded from listener events to avoid accidental
credential or personal-data logging.
