from .main import main
import sys

if __name__ == "__main__":
    # Allow debugging with --debug flag
    if "--debug" in sys.argv:
        import pdb
        pdb.set_trace()
    main()
