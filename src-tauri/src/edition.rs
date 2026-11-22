#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edition {
    Public,
    Server,
}

pub fn current() -> Edition {
    if env!("SCUM_EDITION") == "public" {
        Edition::Public
    } else {
        Edition::Server
    }
}

pub fn label(edition: Edition) -> &'static str {
    match edition {
        Edition::Public => "public",
        Edition::Server => "server",
    }
}

#[cfg(test)]
mod tests {
    use super::{current, label, Edition};

    #[test]
    fn exposes_the_compile_time_edition() {
        let edition = current();
        assert!(matches!(edition, Edition::Public | Edition::Server));
        assert!(matches!(label(edition), "public" | "server"));
    }
}
