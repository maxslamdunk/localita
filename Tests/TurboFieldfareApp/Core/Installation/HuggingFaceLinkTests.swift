import Testing
@testable import TurboFieldfareAppCore

/// What the Add Model field accepts as a repository.
struct HuggingFaceLinkTests {
    @Test func namesAndLinksToTheSameRepositoryAgree() {
        let forms = [
            "Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2",
            "  Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2\n",
            "https://huggingface.co/Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2",
            "https://huggingface.co/Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2/",
            "huggingface.co/Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2?library=mlx",
            "hf.co/Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2#files",
            "https://huggingface.co/Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2/discussions",
        ]
        for form in forms {
            #expect(HuggingFaceLink(form)
                == HuggingFaceLink("Jiunsong/supergemma4-26b-uncensored-mlx-4bit-v2"), "\(form)")
            #expect(HuggingFaceLink(form)?.revision == "main", "\(form)")
        }
    }

    @Test func aLinkIntoABranchOrCommitKeepsIt() {
        let tree = HuggingFaceLink("https://huggingface.co/owner/model.v1/tree/dev")
        #expect(tree?.repoID == "owner/model.v1")
        #expect(tree?.revision == "dev")
        let file = HuggingFaceLink(
            "https://huggingface.co/owner/model/blob/1ecb7582718b813fc4c7b5c3131b2b7053787f00/config.json")
        #expect(file?.revision == "1ecb7582718b813fc4c7b5c3131b2b7053787f00")
    }

    @Test func otherThingsAreRefused() {
        for text in ["", "model-only", "https://huggingface.co/datasets/owner/data",
                     "https://huggingface.co/spaces/owner/app", "https://github.com/owner/repo",
                     "owner/na me", "owner/../x", "https://huggingface.co/owner"] {
            #expect(HuggingFaceLink(text) == nil, "\(text)")
        }
    }
}
