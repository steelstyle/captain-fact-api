defmodule CaptainFact.Accounts.UserPermissionsTest do
  use CaptainFact.DataCase

  alias CaptainFact.Actions.Recorder
  alias CaptainFact.Accounts.UserPermissions
  alias UserPermissions.PermissionsError

  doctest UserPermissions

  setup do
    banned_user = insert(:user, %{reputation: -4200})
    negative_user = insert(:user, %{reputation: -15})
    new_user = insert(:user, %{reputation: 42})
    positive_user = insert(:user, %{reputation: 80000})
    {:ok, [negative_user: negative_user, new_user: new_user, positive_user: positive_user, banned_user: banned_user]}
  end

  test "for each limitation, we must define all levels" do
    each_limitation(fn {_, _, limitations_tuple} ->
      assert limitations_tuple |> Tuple.to_list() |> Enum.count() == UserPermissions.nb_levels()
    end)
  end

  test "check! loads user if given an id", context do
    max_occurences = UserPermissions.limitation(context[:positive_user], :create, :comment)
    assert UserPermissions.check!(context[:positive_user].id, :create, :comment) == max_occurences
  end

  test "check! ensures permissions are verified and throws exception otherwise", context do
    assert_raise PermissionsError, fn -> UserPermissions.check!(context[:negative_user], :vote_down, :comment) end
  end

  test "check! must fail if we hit the limit", context do
    user = context[:new_user]
    action_type = :create
    entity = :comment
    max_occurences = UserPermissions.limitation(user, action_type, entity)
    for _ <- 0..max_occurences, do: Recorder.record!(user, action_type, entity)
    assert_raise PermissionsError, fn -> UserPermissions.check!(user, action_type, entity) end
  end

  test "add video has a weekly limit", _ do
    # User with 200 reputation should be able to add 1 video / week
    user = insert(:user, %{reputation: 200, is_publisher: false})
    action_type = :add
    entity = :video
    max_occurences = UserPermissions.limitation(user, action_type, entity)
    actions = for _ <- 0..max_occurences, do: Recorder.record!(user, action_type, entity)
    two_days_ago = NaiveDateTime.add(NaiveDateTime.utc_now, -(2 * 24 * 60 * 60))
    for action <- actions do
      DB.Repo.update(Ecto.Changeset.change(action, inserted_at: two_days_ago))
    end
    assert_raise PermissionsError, fn -> UserPermissions.check!(user, action_type, entity) end
  end

  test "running check! and record! concurrently isn't messing up with state", context do
    user = context[:new_user]
    action_type = :create
    entity = :comment
    max_occurences = UserPermissions.limitation(user, action_type, entity)
    nb_threads = max_occurences * 2
    tolerated_errors = 10
    Stream.repeatedly(fn ->
      Process.sleep(10) # To better simulate requests
      Task.async(fn ->
        try do
          UserPermissions.check!(user, action_type, entity)
          Recorder.record!(user, action_type, entity)
        rescue e in PermissionsError -> e end
      end)
    end)
    |> Enum.take(nb_threads)
    |> Enum.map(&Task.await/1)
    assert Recorder.count(user, action_type, entity) - tolerated_errors <= max_occurences
  end

  test "users with too low reputation shouldn't be able to do anything", context do
    each_limitation(fn {action_type, entity, _} ->
      assert UserPermissions.check(context[:banned_user], action_type, entity) == {:error, "not_enough_reputation"}
    end)
  end

  test "unauthorized users should never pass UserPermissions" do
    each_limitation(fn {action_type, entity, _} ->
      assert UserPermissions.check(nil, action_type, entity) == {:error, "unauthorized"}
    end)
  end

  test "nil user will throw UserPermissions error" do
    # Check
    assert_raise PermissionsError, fn -> UserPermissions.check!(nil, :add, :video) end
  end

  test "users with is_publisher set to true can always add videos without limits" do
    user = insert(:user, %{reputation: 0, is_publisher: true})
    assert UserPermissions.check(user, :add, :video) == {:ok, -1}
  end

  defp each_limitation(func) do
    for {action_type, entities_limitations} <- UserPermissions.limitations do
      case entities_limitations do
        limitation when is_tuple(limitation) -> nil # Ignore wildcards (cannot guess entity)
        limitations when is_map(limitations) ->
          for {entity, limitation} <- limitations do
            func.({action_type, entity, limitation})
          end
      end
    end
  end
end
