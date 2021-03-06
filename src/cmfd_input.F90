module cmfd_input

  use global

  implicit none
  private
  public :: configure_cmfd

contains

!===============================================================================
! CONFIGURE_CMFD initializes CMFD parameters
!===============================================================================

  subroutine configure_cmfd()

    use cmfd_header,  only: allocate_cmfd
    use message_passing, only: master

    integer :: color    ! color group of processor

    ! Read in cmfd input file
    call read_cmfd_xml()

    ! Assign color
    if (master) then
      color = 1
    else
      color = 2
    end if

    ! Initialize timers
    call time_cmfd % reset()
    call time_cmfdbuild % reset()
    call time_cmfdsolve % reset()

    ! Allocate cmfd object
    call allocate_cmfd(cmfd, n_batches)

  end subroutine configure_cmfd

!===============================================================================
! READ_INPUT reads the CMFD input file and organizes it into a data structure
!===============================================================================

  subroutine read_cmfd_xml()

    use constants, only: ZERO, ONE
    use error,     only: fatal_error, warning
    use global
    use output,    only: write_message
    use string,    only: to_lower
    use xml_interface
    use, intrinsic :: ISO_FORTRAN_ENV

    integer :: i, g
    integer :: ng
    integer :: n_params
    integer, allocatable :: iarray(:)
    integer, allocatable :: int_array(:)
    logical :: file_exists ! does cmfd.xml exist?
    logical :: found
    character(MAX_LINE_LEN) :: filename
    real(8) :: gs_tol(2)
    type(XMLDocument) :: doc
    type(XMLNode) :: root
    type(XMLNode) :: node_mesh

    ! Read cmfd input file
    filename = trim(path_input) // "cmfd.xml"
    inquire(FILE=filename, EXIST=file_exists)
    if (.not. file_exists) then
      ! CMFD is optional unless it is in on from settings
      if (cmfd_run) then
        call fatal_error("No CMFD XML file, '" // trim(filename) // "' does not&
             & exist!")
      end if
      return
    else

      ! Tell user
      call write_message("Reading CMFD XML file...", 5)

    end if

    ! Parse cmfd.xml file
    call doc % load_file(filename)
    root = doc % document_element()

    ! Get pointer to mesh XML node
    node_mesh = root % child("mesh")

    ! Check if mesh is there
    if (.not. node_mesh % associated()) then
      call fatal_error("No CMFD mesh specified in CMFD XML file.")
    end if

    ! Set spatial dimensions in cmfd object
    call get_node_array(node_mesh, "dimension", cmfd % indices(1:3))

    ! Get number of energy groups
    if (check_for_node(node_mesh, "energy")) then
      ng = node_word_count(node_mesh, "energy")
      if(.not. allocated(cmfd%egrid)) allocate(cmfd%egrid(ng))
      call get_node_array(node_mesh, "energy", cmfd%egrid)
      cmfd % indices(4) = ng - 1 ! sets energy group dimension
      ! If using MG mode, check to see if these egrid points at least match
      ! the MG Data breakpoints
      if (.not. run_CE) then
        do i = 1, ng
          found = .false.
          do g = 1, num_energy_groups + 1
            if (cmfd % egrid(i) == energy_bins(g)) then
              found = .true.
              exit
            end if
          end do
          if (.not. found) then
            call fatal_error("CMFD energy mesh boundaries must align with&
                             & boundaries of multi-group data!")
          end if
        end do
      end if
    else
      if(.not.allocated(cmfd % egrid)) allocate(cmfd % egrid(2))
      cmfd % egrid = [ ZERO, energy_max_neutron ]
      cmfd % indices(4) = 1 ! one energy group
    end if

    ! Set global albedo
    if (check_for_node(node_mesh, "albedo")) then
      call get_node_array(node_mesh, "albedo", cmfd % albedo)
    else
      cmfd % albedo = [ ONE, ONE, ONE, ONE, ONE, ONE ]
    end if

    ! Get acceleration map
    if (check_for_node(node_mesh, "map")) then
      allocate(cmfd % coremap(cmfd % indices(1), cmfd % indices(2), &
           cmfd % indices(3)))
      if (node_word_count(node_mesh, "map") /= &
           product(cmfd % indices(1:3))) then
        call fatal_error('CMFD coremap not to correct dimensions')
      end if
      allocate(iarray(node_word_count(node_mesh, "map")))
      call get_node_array(node_mesh, "map", iarray)
      cmfd % coremap = reshape(iarray,(cmfd % indices(1:3)))
      cmfd_coremap = .true.
      deallocate(iarray)
    end if

    ! Check for normalization constant
    if (check_for_node(root, "norm")) then
      call get_node_value(root, "norm", cmfd % norm)
    end if

    ! Set feedback logical
    if (check_for_node(root, "feedback")) then
      call get_node_value(root, "feedback", cmfd_feedback)
    end if

    ! Set downscatter logical
    if (check_for_node(root, "downscatter")) then
      call get_node_value(root, "downscatter", cmfd_downscatter)
    end if

    ! Reset dhat parameters
    if (check_for_node(root, "dhat_reset")) then
      call get_node_value(root, "dhat_reset", dhat_reset)
    end if

    ! Set monitoring
    if (check_for_node(root, "power_monitor")) then
      call get_node_value(root, "power_monitor", cmfd_power_monitor)
    end if

    ! Output logicals
    if (check_for_node(root, "write_matrices")) then
      call get_node_value(root, "write_matrices", cmfd_write_matrices)
    end if

    ! Run an adjoint calc
    if (check_for_node(root, "run_adjoint")) then
      call get_node_value(root, "run_adjoint", cmfd_run_adjoint)
    end if

    ! Batch to begin cmfd
    if (check_for_node(root, "begin")) &
         call get_node_value(root, "begin", cmfd_begin)

    ! Check for cmfd tally resets
    if (check_for_node(root, "tally_reset")) then
      n_cmfd_resets = node_word_count(root, "tally_reset")
    else
      n_cmfd_resets = 0
    end if
    if (n_cmfd_resets > 0) then
      allocate(int_array(n_cmfd_resets))
      call get_node_array(root, "tally_reset", int_array)
      do i = 1, n_cmfd_resets
        call cmfd_reset % add(int_array(i))
      end do
      deallocate(int_array)
    end if

    ! Get display
    if (check_for_node(root, "display")) &
         call get_node_value(root, "display", cmfd_display)

    ! Read in spectral radius estimate and tolerances
    if (check_for_node(root, "spectral")) &
         call get_node_value(root, "spectral", cmfd_spectral)
    if (check_for_node(root, "shift")) &
         call get_node_value(root, "shift", cmfd_shift)
    if (check_for_node(root, "ktol")) &
         call get_node_value(root, "ktol", cmfd_ktol)
    if (check_for_node(root, "stol")) &
         call get_node_value(root, "stol", cmfd_stol)
    if (check_for_node(root, "gauss_seidel_tolerance")) then
      n_params = node_word_count(root, "gauss_seidel_tolerance")
      if (n_params /= 2) then
        call fatal_error('Gauss Seidel tolerance is not 2 parameters &
                   &(absolute, relative).')
      end if
      call get_node_array(root, "gauss_seidel_tolerance", gs_tol)
      cmfd_atoli = gs_tol(1)
      cmfd_rtoli = gs_tol(2)
    end if

    ! Create tally objects
    call create_cmfd_tally(root)

    ! Close CMFD XML file
    call doc % clear()

  end subroutine read_cmfd_xml

!===============================================================================
! CREATE_CMFD_TALLY creates the tally object for OpenMC to process for CMFD
! accleration.
! There are 3 tally types:
!   1: Only an energy in filter-> flux,total,p1 scatter
!   2: Energy in and energy out filter-> nu-scatter,nu-fission
!   3: Surface current
!===============================================================================

  subroutine create_cmfd_tally(root)

    use constants,        only: MAX_LINE_LEN
    use error,            only: fatal_error, warning
    use mesh_header,      only: RegularMesh
    use string
    use tally,            only: setup_active_cmfdtallies
    use tally_header,     only: TallyObject
    use tally_filter_header
    use tally_filter
    use tally_initialize, only: add_tallies
    use xml_interface

    type(XMLNode), intent(in) :: root ! XML root element

    integer :: i, j        ! loop counter
    integer :: n           ! size of arrays in mesh specification
    integer :: ng          ! number of energy groups (default 1)
    integer :: n_filters   ! number of filters
    integer :: i_filter_mesh ! index for mesh filter
    integer :: iarray3(3) ! temp integer array
    real(8) :: rarray3(3) ! temp double array
    type(TallyObject),    pointer :: t
    type(RegularMesh), pointer :: m
    type(TallyFilterContainer) :: filters(N_FILTER_TYPES) ! temporary filters
    type(XMLNode) :: node_mesh

    ! Set global variables if they are 0 (this can happen if there is no tally
    ! file)
    if (n_meshes == 0) n_meshes = n_user_meshes + n_cmfd_meshes

    ! Allocate mesh
    if (.not. allocated(meshes)) allocate(meshes(n_meshes))
    m => meshes(n_user_meshes+1)

    ! Set mesh id
    m % id = n_user_meshes + 1

    ! Set mesh type to rectangular
    m % type = LATTICE_RECT

    ! Get pointer to mesh XML node
    node_mesh = root % child("mesh")

    ! Determine number of dimensions for mesh
    n = node_word_count(node_mesh, "dimension")
    if (n /= 2 .and. n /= 3) then
      call fatal_error("Mesh must be two or three dimensions.")
    end if
    m % n_dimension = n

    ! Allocate attribute arrays
    allocate(m % dimension(n))
    allocate(m % lower_left(n))
    allocate(m % width(n))
    allocate(m % upper_right(n))

    ! Check that dimensions are all greater than zero
    call get_node_array(node_mesh, "dimension", iarray3(1:n))
    if (any(iarray3(1:n) <= 0)) then
      call fatal_error("All entries on the <dimension> element for a tally mesh&
           & must be positive.")
    end if

    ! Read dimensions in each direction
    m % dimension = iarray3(1:n)

    ! Read mesh lower-left corner location
    if (m % n_dimension /= node_word_count(node_mesh, "lower_left")) then
      call fatal_error("Number of entries on <lower_left> must be the same as &
           &the number of entries on <dimension>.")
    end if
    call get_node_array(node_mesh, "lower_left", m % lower_left)

    ! Make sure both upper-right or width were specified
    if (check_for_node(node_mesh, "upper_right") .and. &
         check_for_node(node_mesh, "width")) then
      call fatal_error("Cannot specify both <upper_right> and <width> on a &
           &tally mesh.")
    end if

    ! Make sure either upper-right or width was specified
    if (.not.check_for_node(node_mesh, "upper_right") .and. &
         .not.check_for_node(node_mesh, "width")) then
      call fatal_error("Must specify either <upper_right> and <width> on a &
           &tally mesh.")
    end if

    if (check_for_node(node_mesh, "width")) then
      ! Check to ensure width has same dimensions
      if (node_word_count(node_mesh, "width") /= &
           node_word_count(node_mesh, "lower_left")) then
        call fatal_error("Number of entries on <width> must be the same as the &
             &number of entries on <lower_left>.")
      end if

      ! Check for negative widths
      call get_node_array(node_mesh, "width", rarray3(1:n))
      if (any(rarray3(1:n) < ZERO)) then
        call fatal_error("Cannot have a negative <width> on a tally mesh.")
      end if

      ! Set width and upper right coordinate
      m % width = rarray3(1:n)
      m % upper_right = m % lower_left + m % dimension * m % width

    elseif (check_for_node(node_mesh, "upper_right")) then
      ! Check to ensure width has same dimensions
      if (node_word_count(node_mesh, "upper_right") /= &
           node_word_count(node_mesh, "lower_left")) then
        call fatal_error("Number of entries on <upper_right> must be the same &
             &as the number of entries on <lower_left>.")
      end if

      ! Check that upper-right is above lower-left
      call get_node_array(node_mesh, "upper_right", rarray3(1:n))
      if (any(rarray3(1:n) < m % lower_left)) then
        call fatal_error("The <upper_right> coordinates must be greater than &
             &the <lower_left> coordinates on a tally mesh.")
      end if

      ! Set upper right coordinate and width
      m % upper_right = rarray3(1:n)
      m % width = (m % upper_right - m % lower_left) / real(m % dimension, 8)
    end if

    ! Set volume fraction
    m % volume_frac = ONE/real(product(m % dimension),8)

    ! Add mesh to dictionary
    call mesh_dict % add_key(m % id, n_user_meshes + 1)

    ! Allocate tallies
    call add_tallies("cmfd", n_cmfd_tallies)

    ! Begin loop around tallies
    do i = 1, n_cmfd_tallies

      ! Point t to tally variable
      t => cmfd_tallies(i)

      ! Set reset property
      if (check_for_node(root, "reset")) then
        call get_node_value(root, "reset", t % reset)
      end if

      ! Set up mesh filter
      n_filters = 1
      allocate(MeshFilter :: filters(n_filters) % obj)
      select type (filt => filters(n_filters) % obj)
      type is (MeshFilter)
        filt % n_bins = product(m % dimension)
        filt % mesh = n_user_meshes + 1
      end select
      t % find_filter(FILTER_MESH) = n_filters

      ! Read and set incoming energy mesh filter
      if (check_for_node(node_mesh, "energy")) then
        n_filters = n_filters + 1
        allocate(EnergyFilter :: filters(n_filters) % obj)
        select type (filt => filters(n_filters) % obj)
        type is (EnergyFilter)
          ng = node_word_count(node_mesh, "energy")
          filt % n_bins = ng - 1
          allocate(filt % bins(ng))
          call get_node_array(node_mesh, "energy", filt % bins)
        end select
        t % find_filter(FILTER_ENERGYIN) = n_filters
      end if

      ! Set number of nucilde bins
      allocate(t % nuclide_bins(1))
      t % nuclide_bins(1) = -1
      t % n_nuclide_bins = 1

      ! Record tally id which is equivalent to loop number
      t % id = i_cmfd_tallies + i

      if (i == 1) then

        ! Set name
        t % name = "CMFD flux, total, scatter-1"

        ! Set tally estimator to analog
        t % estimator = ESTIMATOR_ANALOG

        ! Set tally type to volume
        t % type = TALLY_VOLUME

        ! Allocate and set filters
        allocate(t % filters(n_filters))
        do j = 1, n_filters
          call move_alloc(filters(j) % obj, t % filters(j) % obj)
        end do

        ! Allocate scoring bins
        allocate(t % score_bins(3))
        t % n_score_bins = 3
        t % n_user_score_bins = 3

        ! Allocate scattering order data
        allocate(t % moment_order(3))
        t % moment_order = 0

        ! Set macro_bins
        t % score_bins(1)  = SCORE_FLUX
        t % score_bins(2)  = SCORE_TOTAL
        t % score_bins(3)  = SCORE_SCATTER_N
        t % moment_order(3) = 1

      else if (i == 2) then

        ! Set name
        t % name = "CMFD neutron production"

        ! Set tally estimator to analog
        t % estimator = ESTIMATOR_ANALOG

        ! Set tally type to volume
        t % type = TALLY_VOLUME

        ! read and set outgoing energy mesh filter
        if (check_for_node(node_mesh, "energy")) then
          n_filters = n_filters + 1
          allocate(EnergyoutFilter :: filters(n_filters) % obj)
          select type (filt => filters(n_filters) % obj)
          type is (EnergyoutFilter)
            ng = node_word_count(node_mesh, "energy")
            filt % n_bins = ng - 1
            allocate(filt % bins(ng))
            call get_node_array(node_mesh, "energy", filt % bins)
          end select
          t % find_filter(FILTER_ENERGYOUT) = n_filters
        end if

        ! Allocate and set filters
        allocate(t % filters(n_filters))
        do j = 1, n_filters
          call move_alloc(filters(j) % obj, t % filters(j) % obj)
        end do

        ! Allocate macro reactions
        allocate(t % score_bins(2))
        t % n_score_bins = 2
        t % n_user_score_bins = 2

        ! Allocate scattering order data
        allocate(t % moment_order(2))
        t % moment_order = 0

        ! Set macro_bins
        t % score_bins(1) = SCORE_NU_SCATTER
        t % score_bins(2) = SCORE_NU_FISSION

      else if (i == 3) then

        ! Set name
        t % name = "CMFD surface currents"

        ! Set tally estimator to analog
        t % estimator = ESTIMATOR_ANALOG

        ! Add extra filter for surface
        n_filters = n_filters + 1
        allocate(SurfaceFilter :: filters(n_filters) % obj)
        select type(filt => filters(n_filters) % obj)
        type is(SurfaceFilter)
          filt % n_bins = 4 * m % n_dimension
          allocate(filt % surfaces(4 * m % n_dimension))
          if (m % n_dimension == 2) then
            filt % surfaces = (/ OUT_LEFT, IN_LEFT, IN_RIGHT, OUT_RIGHT, &
                 OUT_BACK, IN_BACK, IN_FRONT, OUT_FRONT /)
          elseif (m % n_dimension == 3) then
            filt % surfaces = (/ OUT_LEFT, IN_LEFT, IN_RIGHT, OUT_RIGHT, &
                 OUT_BACK, IN_BACK, IN_FRONT, OUT_FRONT, &
                 OUT_BOTTOM, IN_BOTTOM, IN_TOP, OUT_TOP /)
          end if
        end select
        t % find_filter(FILTER_SURFACE) = n_filters

        ! Allocate and set filters
        allocate(t % filters(n_filters))
        do j = 1, n_filters
          call move_alloc(filters(j) % obj, t % filters(j) % obj)
        end do

        ! Allocate macro reactions
        allocate(t % score_bins(1))
        t % n_score_bins = 1
        t % n_user_score_bins = 1

        ! Allocate scattering order data
        allocate(t % moment_order(1))
        t % moment_order = 0

        ! Set macro bins
        t % score_bins(1) = SCORE_CURRENT
        t % type = TALLY_SURFACE_CURRENT

        ! We need to increase the dimension by one since we also need
        ! currents coming into and out of the boundary mesh cells.
        i_filter_mesh = t % find_filter(FILTER_MESH)
        t % filters(i_filter_mesh) % obj % n_bins = product(m % dimension + 1)

      end if

    end do

    ! Put cmfd tallies into active tally array and turn tallies on
!$omp parallel
    call setup_active_cmfdtallies()
!$omp end parallel
    tallies_on = .true.

  end subroutine create_cmfd_tally

end module cmfd_input
