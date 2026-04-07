Mimic.copy(Gingko.TestSupport.Mnemosyne.MockLLM, type_check: true)

test_db_path =
  :gingko
  |> Application.get_env(Gingko.Repo, [])
  |> Keyword.fetch!(:database)

for suffix <- ["", "-shm", "-wal"] do
  File.rm(test_db_path <> suffix)
end

{:ok, _} = Application.ensure_all_started(:gingko)

ExUnit.start()
