%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/",
          "mix.exs"
        ],
        excluded: [
          "_build/",
          "deps/"
        ]
      },
      strict: true
    }
  ]
}
